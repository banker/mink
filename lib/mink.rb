STDOUT.sync = true

$:.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'mongo'
require 'thread'

require 'mink/helpers/manager_helper'
require 'mink/managers/repl_set_manager'
require 'mink/managers/auth_repl_set_manager'
require 'mink/managers/sharding_manager'

module Mink
  VERSION = "0.1"
end
