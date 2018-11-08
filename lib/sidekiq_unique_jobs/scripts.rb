# frozen_string_literal: true

require 'pathname'
require 'digest/sha1'
require 'concurrent/map'
require 'sidekiq_unique_jobs/scripts/acquire_lock'
require 'sidekiq_unique_jobs/scripts/release_lock'

module SidekiqUniqueJobs
  ScriptError         = Class.new(StandardError)
  UniqueKeyMissing    = Class.new(ArgumentError)
  JidMissing          = Class.new(ArgumentError)
  MaxLockTimeMissing  = Class.new(ArgumentError)
  UnexpectedValue     = Class.new(StandardError)

  module Scripts
    LUA_PATHNAME ||= Pathname.new(__FILE__).dirname.join('../../redis').freeze
    SOURCE_FILES ||= Dir[LUA_PATHNAME.join('**/*.lua')].compact.freeze
    DEFINED_METHODS ||= [].freeze
    SCRIPT_SHAS ||= Concurrent::Map.new

    module_function

    extend SingleForwardable
    def_delegators :SidekiqUniqueJobs, :connection, :logger

    def call(file_name, redis_pool, options = {})
      internal_call(file_name, redis_pool, options)
    rescue Redis::CommandError => ex
      handle_error(ex, file_name, redis_pool, options)
    end

    def internal_call(file_name, redis_pool, options = {})
      redis(redis_pool) do |conn|
        sha = script_sha(conn, file_name)
        conn.evalsha(sha, options)
      end
    end

    def script_sha(conn, file_name)
      if (sha = SCRIPT_SHAS.get(file_name))
        return sha
      end

      sha = conn.script(:load, script_source(file_name))
      SCRIPT_SHAS.put(file_name, sha)
      sha
    end

    def handle_error(ex, file_name, redis_pool, options = {})
      if ex.message == 'NOSCRIPT No matching script. Please use EVAL.' # rubocop:disable Style/GuardClause
        SCRIPT_SHAS.delete(file_name)
        call(file_name, redis_pool, options)
      else
        raise ScriptError, "Problem compiling #{file_name}. Invalid LUA syntax?"
      end
    end

    def script_source(file_name)
      script_path(file_name).read
    end

    def script_path(file_name)
      LUA_PATHNAME.join("#{file_name}.lua")
    end

    def redis(redis_pool = nil)
      if redis_pool
        redis_pool.with { |conn| yield conn }
      else
        Sidekiq.redis { |conn| yield conn }
      end
    end

  end
end
