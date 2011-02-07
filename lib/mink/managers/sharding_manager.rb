module Mink
  class ShardingManager
    include ManagerHelper

    attr_accessor :shards

    def initialize(opts={})
      @durable = opts.fetch(:durable, true)

      @mongos_port  = opts.fetch(:mongos_start_port, 50000)
      @config_port  = opts.fetch(:config_server_start_port, 40000)
      @working_dir  = opts.fetch(:working_dir, nil)
      @mongod_path  = opts.fetch(:mongod_path, "mongod")
      @mongos_path  = opts.fetch(:mongos_path, "mongos")
      @write_conf   = opts.fetch(:write_conf, false)
      @host         = opts.fetch(:host, "localhost")

      @shard_count  = opts.fetch(:shard_count, 2)
      @mongos_count = opts.fetch(:mongos_count, 1)
      @config_server_count = opts.fetch(:config_server_count, 1)
      @replica_set_config  = opts.fetch(:replica_set_config, {})

      @shard_db     = opts.fetch(:shard_database, "app")
      @shard_coll   = opts.fetch(:shard_collection, "images")
      @shard_key    = opts.fetch(:shard_key, {:tid => 1})

      if ![1, 3].include?(@config_server_count)
        raise ArgumentError, "Must specify 1 or 3 config servers."
      end

      @pidlistfile  = File.join(@working_dir, "mink.pidlist")
      @data_path    = opts.fetch(:path, File.join(@working_dir, "data"))

      @config_servers = {}
      @mongos_servers = {}
      @shards = []
      @ports  = []
      @pids   = []
    end

    def start_cluster
      kill_existing_mongods
      kill_existing_mongos
      start_sharding_components
      start_mongos_servers
      configure_cluster
    end

    def configure_cluster
      add_shards
      enable_sharding
      if shard_collection
        STDOUT << "\nShard cluster initiated!\nEnter the following to connect:\n  mongo localhost:#{@mongos_port}\n\n"
      end
    end

    def enable_sharding
      cmd = {:enablesharding => @shard_db}
      STDOUT << "Command: #{cmd.inspect}\n"
      mongos['admin'].command(cmd)
    end

    def shard_collection
      cmd = BSON::OrderedHash.new
      cmd[:shardcollection] = "#{@shard_db}.#{@shard_coll}"
      cmd[:key] = {:tid => 1}
      STDOUT << "Command: #{cmd.inspect}\n"
      mongos['admin'].command(cmd)
    end

    def add_shards
      @shards.each do |shard|
        cmd = {:addshard => shard.shard_string}
        cmd
        STDOUT << "Command: #{cmd.inspect}\n"
        p mongos['admin'].command(cmd)
      end
      p mongos['admin'].command({:listshards => 1})
    end

    def mongos
      attempt do
        @mongos ||= Mongo::Connection.new(@host, @mongos_servers[0]['port'])
      end
    end

    def kill_random
      shard_to_kill = rand(@shard_count)
      @shards[shard_to_kill].kill_primary
    end

    def restart_killed
      threads = []
      @shards.each do |k, shard|
        threads << Thread.new do
          shard.restart_killed_nodes
        end
      end
    end

    private

    def start_sharding_components
      system("killall mongos")

      threads = []
      threads << Thread.new do
        start_shards
      end

      threads << Thread.new do
        start_config_servers
      end

      threads.each {|t| t.join}

      puts "\nShards and config servers up!"
    end

    def start_shards
      threads = []

      @shard_count.times do |n|
          threads << Thread.new do
          port = @replica_set_config[:start_port] + n * 100
          name = "shard-#{n}-#{@replica_set_config[:name]}"
          shard = ReplSetManager.new(@replica_set_config.merge(:start_port => port, :name => name))
          shard.start_set
          @shards << shard
        end
      end

      threads.each {|t| t.join}

      @shards.each do |shard|
        @pids << shard.pids
      end
    end

    def start_config_servers
      @config_server_count.times do |n|
        @config_servers[n] ||= {}
        port = @config_port + n
        @ports << port
        @config_servers[n]['port'] = port
        @config_servers[n]['db_path'] = get_path("config-#{port}.data")
        @config_servers[n]['log_path'] = get_path("config-#{port}.log")
        system("rm -rf #{@config_servers[n]['db_path']}")
        system("mkdir -p #{@config_servers[n]['db_path']}")

        @config_servers[n]['start'] = start_config_cmd(n)

        start(@config_servers, n)
      end
    end

    def start_mongos_servers
      @mongos_count.times do |n|
        @mongos_servers[n] ||= {}
        port = @mongos_port + n
        @ports << port
        @mongos_servers[n]['port'] = port
        @mongos_servers[n]['db_path'] = get_path("mongos-#{port}.data")
        @mongos_servers[n]['pidfile_path'] = File.join(@mongos_servers[n]['db_path'], "mongod.lock")
        @mongos_servers[n]['log_path'] = get_path("mongos-#{port}.log")
        system("rm -rf #{@mongos_servers[n]['db_path']}")
        system("mkdir -p #{@mongos_servers[n]['db_path']}")

        @mongos_servers[n]['start'] = start_mongos_cmd(n)

        start(@mongos_servers, n)
      end
    end

    def start_config_cmd(n)
      cmd = "mongod --configsvr --logpath '#{@config_servers[n]['log_path']}' " +
       " --dbpath #{@config_servers[n]['db_path']} --port #{@config_servers[n]['port']} --fork"
      cmd += " --dur" if @durable
      cmd
    end

    def start_mongos_cmd(n)
      "mongos --configdb #{config_db_string} --logpath '#{@mongos_servers[n]['log_path']}' " +
        "--pidfilepath #{@mongos_servers[n]['pidfile_path']} --port #{@mongos_servers[n]['port']} --fork"
    end

    def config_db_string
      @config_servers.map do |k, v|
        "#{@host}:#{v['port']}"
      end.join(',')
    end

    def start(set, node)
      system(set[node]['start'])
      set[node]['up'] = true
      sleep(0.75)
      set[node]['pid'] = File.open(File.join(set[node]['db_path'], 'mongod.lock')).read.strip
    end
    alias :restart :start

  end
end
