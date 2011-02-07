module Mink
  class ReplSetManager
    include ManagerHelper

    attr_accessor :host, :start_port, :ports, :name, :mongods, :pids

    def initialize(opts={})
      @durable     = opts.fetch(:durable, false)
      @start_port  = opts.fetch(:start_port, 30000)
      @name        = opts.fetch(:name, 'replica-set-foo')
      @host        = opts.fetch(:host, 'localhost')
      @working_dir = opts.fetch(:working_dir, nil)
      @mongod_path = opts.fetch(:mongod_path, "mongod")
      @write_conf  = opts.fetch(:write_conf, false)
      @write_pids  = opts.fetch(:write_pids, false)
      @replica_count   = opts[:replica_count] || 2
      @arbiter_count   = opts[:arbiter_count] || 2
      @passive_count   = opts[:passive_count] || 1
      check_member_count

      if !@working_dir
        raise ArgumentError, "A working directory must be specified"
      end

      @data_path    = opts.fetch(:path, File.join(@working_dir, "data"))
      @pidlistfile  = File.join(@working_dir, "mink.pidlist")

      @ports      = []
      @mongods    = []
      @pids       = []
      @config     = {"_id" => @name, "members" => []}
    end

    def start_set
      puts "** Starting a replica set with #{@count} nodes"
      kill_existing_mongods

      n = 0
      @replica_count.times do |n|
        configure_node(n)
        n += 1
      end

      @passive_count.times do
        configure_node(n) do |attrs|
          attrs['priority'] = 0
        end
        n += 1
      end

      @arbiter_count.times do
        configure_node(n) do |attrs|
          attrs['arbiterOnly'] = true
        end
        n += 1
      end

      write_conf if @write_conf
      startup_mongods
      initiate_repl_set
      ensure_up
    end

    def cleanup_set
      system("killall mongod")
      @mongods.each do |mongod|
        system("rm -rf #{mongod['db_path']}")
      end
    end

    def configure_node(n)
      @mongods[n] ||= {}
      port = @start_port + n
      @ports << port
      @mongods[n]['port'] = port
      @mongods[n]['db_path'] = get_path("#{port}.data")
      @mongods[n]['log_path'] = get_path("#{port}.log")

      @mongods[n]['start'] = start_cmd(n)

      member = {'_id' => n, 'host' => "#{@host}:#{@mongods[n]['port']}"}

      if block_given?
        custom_attrs = {}
        yield custom_attrs
        member.merge!(custom_attrs)
        @mongods[n].merge!(custom_attrs)
      end

      @config['members'] << member
    end

    def start_cmd(n)
      @mongods[n]['start'] = "#{@mongod_path} --replSet #{@name} --logpath '#{@mongods[n]['log_path']}' " +
       " --dbpath #{@mongods[n]['db_path']} --port #{@mongods[n]['port']} --fork"
      @mongods[n]['start'] += " --dur" if @durable
      @mongods[n]['start']
    end

    def kill(node, signal=2)
      pid = @mongods[node]['pid']
      puts "** Killing node with pid #{pid} at port #{@mongods[node]['port']}"
      system("kill -#{signal} #{@mongods[node]['pid']}")
      @mongods[node]['up'] = false
      sleep(1)
    end

    def kill_primary(signal=2)
      node = get_node_with_state(1)
      kill(node, signal)
      return node
    end

    def step_down_primary
      primary = get_node_with_state(1)
      con = get_connection(primary)
      begin
        con['admin'].command({'replSetStepDown' => 90})
      rescue Mongo::ConnectionFailure
      end
    end

    def kill_secondary
      node = get_node_with_state(2)
      kill(node)
      return node
    end

    def restart_killed_nodes
      nodes = @mongods.select do |mongods|
        @mongods['up'] == false
      end

      nodes.each do |node|
        start(node)
      end

      ensure_up
    end

    def get_node_from_port(port)
      @mongods.detect { |mongod| mongod['port'] == port }
    end

    def start(node)
      system(@mongods[node]['start'])
      @mongods[node]['up'] = true
      sleep(0.5)
      @mongods[node]['pid'] = File.open(File.join(@mongods[node]['db_path'], 'mongod.lock')).read.strip
    end
    alias :restart :start

    def ensure_up
      print "[RS #{@name}] Ensuring members are up...\n"

      attempt do
        con = get_connection
        status = con['admin'].command({'replSetGetStatus' => 1})
        print "."
        if status['members'].all? { |m| m['health'] == 1 && [1, 2, 7].include?(m['state']) } &&
           status['members'].any? { |m| m['state'] == 1 }
          print "all members up!\n\n"
          return status
        else
          raise Mongo::OperationFailure
        end
      end
    end

    def primary
      nodes = get_all_host_pairs_with_state(1)
      nodes.empty? ? nil : nodes[0]
    end

    def secondaries
      get_all_host_pairs_with_state(2)
    end

    def arbiters
      get_all_host_pairs_with_state(7)
    end

    # String used for adding a shard via mongos
    # using the addshard command.
    def shard_string
      str = "#{@name}/"
      str << @mongods.select do |mongod|
        !mongod['arbiterOnly'] && mongod['priority'] != 0
      end.map do |mongod|
        "#{@host}:#{mongod['port']}"
      end.join(',')
      str
    end

    def get_manual_conf
    end

    def write_conf(filename=nil)
    end

    private

    def startup_mongods
      @mongods.each do |mongod|
        system("rm -rf #{mongod['db_path']}")
        system("mkdir -p #{mongod['db_path']}")
        system(mongod['start'])
        mongod['up'] = true
        sleep(0.5)
        pid = File.open(File.join(mongod['db_path'], 'mongod.lock'), "r").read.strip
        mongod['pid'] = pid
        @pids << pid
      end
    end

    def initiate_repl_set
      con = get_connection

      attempt do
        con['admin'].command({'replSetInitiate' => @config})
      end
    end

    def get_node_with_state(state)
      status = ensure_up
      node = status['members'].detect {|m| m['state'] == state}
      if node
        host_port = node['name'].split(':')
        port = host_port[1] ? host_port[1].to_i : 27017
        key = @mongods.keys.detect {|key| @mongods[key]['port'] == port}
        return key
      else
        return false
      end
    end

    def get_all_host_pairs_with_state(state)
      status = ensure_up
      nodes = status['members'].select {|m| m['state'] == state}
      nodes.map do |node|
        host_port = node['name'].split(':')
        port = host_port[1] ? host_port[1].to_i : 27017
        [host, port]
      end
    end

    def get_connection(node=nil)
      con = attempt do
        if !node
          node = @mongods.detect {|mongod| !mongod['arbiterOnly'] && mongod['up'] }
        end
        con = Mongo::Connection.new(@host, node['port'], :slave_ok => true)
      end

      return con
    end

    def check_member_count
      @count = @replica_count + @arbiter_count + @passive_count

      if @count > 7
        raise StandardError, "Cannot create a replica set with #{node_count} nodes. 7 is the max."
      end
    end
  end
end
