STDOUT.sync = true

$:.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'mongo'
require 'thread'
require 'rbconfig'

require 'mink/helpers/manager_helper'
require 'mink/managers/repl_set_manager'
require 'mink/managers/auth_repl_set_manager'
require 'mink/managers/sharding_manager'

module Mink
  VERSION = "0.1.1"
end

if Config::CONFIG['host_os'] =~ /mswin|windows/i
  STDERR << "Sorry, but mink doesn't work on Windows yet. Stay tuned."
  exit
end
