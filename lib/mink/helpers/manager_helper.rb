module Mink
  module ManagerHelper

    def get_path(name)
      File.join(@working_dir, name)
    end

    def attempt
      raise "No block given!" unless block_given?
      count = 0
      begin
        return yield
        rescue Mongo::OperationFailure, Mongo::ConnectionFailure => ex
          sleep(1)
          count += 1
        retry if count < 60
      end

      raise ex
    end

    def kill_existing_mongods
      if File.exists?(@pidlistfile)
        pids = YAML.load(File.open(@pidlistfile, "r").read)
        kill_pidlist(pids)
      else
        system("killall mongod")
      end
    end

    def kill_existing_mongos
      if File.exists?(@pidlistfile)
        pids = YAML.load(File.open(@pidlistfile, "r").read)
        kill_pidlist(pids)
      else
        system("killall mongos")
      end
    end

    def kill_pidlist(pids)
      pids.each do |pid|
        system("kill -9 #{pid}")
      end
    end
  end
end
