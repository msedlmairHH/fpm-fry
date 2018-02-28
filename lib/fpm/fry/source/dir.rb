require 'fpm/fry/source'
require 'fpm/fry/exec'
require 'fileutils'
require 'digest'
require 'cabin/channel'
require 'fpm/fry/tar'

module FPM; module Fry ; module Source
  class Dir

    REGEX = %r!\A(?:file:|/|\.)!

    def self.name
      :dir
    end

    def self.guess( url )
      Source::guess_regex(REGEX, url)
    end

    class Cache < Struct.new(:package, :dir)
      extend Forwardable

      def_delegators :package, :url, :logger, :file_map, :to

      def tar_io
        Exec::popen('tar','-c','.', chdir: dir, logger: logger)
      end

      def copy_to(dst)
        children = ::Dir.new(dir).select{|x| x[0...1] != "." }.map{|x| File.join(dir,x) }
        FileUtils.cp_r(children, dst)
      end

      def cachekey
        dig = Digest::SHA2.new
        tar_io.each(1024) do |block|
          dig << block
        end
        return dig.hexdigest
      end

      def prefix
        Source::prefix(dir)
      end
    end

    attr :url, :logger, :file_map, :to

    def initialize( url, options = {} )
      @url = URI(url)
      if @url.relative?
        @url.path = File.expand_path(@url.path)
      end
      @logger = options.fetch(:logger){ Cabin::Channel.get }
      @file_map = options[:file_map]
      @to = options[:to]
    end

    def build_cache(_)
      Cache.new(self, url.path)
    end
  end
end ; end ; end

