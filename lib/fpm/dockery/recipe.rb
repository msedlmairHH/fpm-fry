require 'fpm/dockery/source'
require 'fpm/dockery/source/package'
require 'fpm/dockery/source/dir'
require 'fpm/dockery/source/patched'
require 'fpm/dockery/source/git'
require 'fpm/dockery/plugin'
require 'fpm/dockery/os_db'
require 'shellwords'
require 'cabin'
require 'open3'
module FPM; module Dockery

  class Recipe

    Not = Module.new

    class NotFound < StandardError
    end

    class Builder < Struct.new(:variables, :recipe)

      attr :logger

      def flavour
        variables[:flavour]
      end

      def distribution
        variables[:distribution]
      end
      alias platform distribution

      def distribution_version
        variables[:distribution_version]
      end
      alias platform_version distribution_version

      def codename
        variables[:codename]
      end

      def initialize( variables, recipe = Recipe.new, options = {})
        variables = variables.dup
        if variables[:distribution] && !variables[:flavour] && OsDb[variables[:distribution]]
          variables[:flavour] = OsDb[variables[:distribution]][:flavour]
        end
        if !variables[:codename] && OsDb[variables[:distribution]] && variables[:distribution_version]
          codename = OsDb[variables[:distribution]][:codenames].find{|name,version| variables[:distribution_version].start_with? version }
          variables[:codename] = codename[0] if codename
        end
        variables.freeze
        super(variables, recipe)
        @logger = options.fetch(:logger){ Cabin::Channel.get }
      end

      def load_file( file )
        file = File.expand_path(file)
        begin
          content = IO.read(file)
        rescue Errno::ENOENT => e
          raise NotFound, e
        end
        basedir = File.dirname(file)
        Dir.chdir(basedir) do
          instance_eval(content,file,0)
        end
      end

      def iteration(value = Not)
        get_or_set('@iteration',value)
      end
      alias revision iteration

      def version(value = Not)
        get_or_set('@version',value)
      end

      def name(value = Not)
        get_or_set('@name',value)
      end

      def vendor(value = Not)
        get_or_set('@vendor',value)
      end

      def build_depends( name , options = {} )
        name, options = parse_package(name, options)
        recipe.build_depends[name] = options
      end

      def depends( name , options = {} )
        name, options = parse_package(name, options)
        recipe.depends[name] = options
      end

      def conflicts( name , options = {} )
        name, options = parse_package(name, options)
        recipe.conflicts[name] = options
      end

      def provides( name , options = {} )
        name, options = parse_package(name, options)
        recipe.provides[name] = options
      end

      def replaces( name , options = {} )
        name, options = parse_package(name, options)
        recipe.replaces[name] = options
      end

      def source( url , options = {} )
        options = options.merge(logger: logger)
        source = Source::Patched.decorate(options) do |options|
          guess_source(url,options).new(url, options)
        end
        get_or_set('@source',source)
      end

      def run(*args)
        if args.first.kind_of? Hash
          options = args.shift
        else
          options = {}
        end
        command = args.shift
        name = options.fetch(:name){ [command,*args].select{|c| c[0] != '-' }.join('-') }
        recipe.steps[name] = Shellwords.join([command, *args])
      end

      def plugin(name, *args, &block)
        logger.debug('Loading Plugin', name: name, args: args, block: block, load_path: $LOAD_PATH)
        if name =~ /\A\./
          require name
        else
          require File.join('fpm/dockery/plugin',name)
        end
        module_name = File.basename(name,'.rb').gsub(/(?:\A|_)([a-z])/){ $1.upcase }
        mod = FPM::Dockery::Plugin.const_get(module_name)
        if mod.respond_to? :apply
          mod.apply(self, *args, &block)
        else
          extend(mod)
        end
      end

      def script(type, value)
        recipe.scripts[type] << value
      end

      def before_install(*args)
        script(:before_install, *args)
      end
      alias pre_install before_install
      alias preinstall before_install

      def after_install(*args)
        script(:after_install, *args)
      end
      alias post_install after_install
      alias postinstall after_install

      def before_remove(*args)
        script(:before_remove, *args)
      end
      alias before_uninstall before_remove
      alias pre_uninstall before_remove
      alias preuninstall before_remove

      def after_remove(*args)
        script(:after_remove, *args)
      end
      alias after_uninstall after_remove
      alias post_uninstall after_remove
      alias postuninstall after_remove

    protected

      def parse_package( name, options = {} )
        if options.kind_of? String
          options = {version: options}
        end
        return name, options
      end

      def source_types
        @source_types  ||= {
          git:  Source::Git,
          http: Source::Package,
          tar:  Source::Package,
          dir:  Source::Dir
        }
      end

      def register_source_type( name, klass )
        if !klass.respond_to? :new
          raise ArgumentError.new("Expected something that responds to :new, got #{klass.inspect}")
        end
        source_types[name] = klass
      end

      NEG_INF = (-1.0/0.0)

      def guess_source( url, options = {} )
        if w = options[:with]
          return source_types.fetch(w){ raise ArgumentError.new("Unknown source type: #{w}") }
        end
        scores = source_types.values.uniq\
          .select{|klass| klass.respond_to? :guess }\
          .group_by{|klass| klass.guess(url) }\
          .sort_by{|score,_| score.nil? ? NEG_INF : score }
        score, klasses = scores.last
        if score == nil
          raise ArgumentError.new("No source provide found for #{url}.\nMaybe try explicitly setting the type using :with parameter. Valid options are: #{source_types.keys.join(', ')}")
        end
        if klasses.size != 1
          raise ArgumentError.new("Multiple possible source providers found for #{url}: #{klasses.join(', ')}.\nMaybe try explicitly setting the type using :with parameter. Valid options are: #{source_types.keys.join(', ')}")
        end
        return klasses.first
      end

      def get_or_set(name, value = Not)
        if value == Not
          return recipe.instance_variable_get(name)
        else
          return recipe.instance_variable_set(name, value)
        end
      end
    end

    attr :name,
      :iteration,
      :version,
      :maintainer,
      :vendor,
      :source,
      :build_depends,
      :depends,
      :provides,
      :conflicts,
      :replaces,
      :suggests,
      :recommends,
      :steps,
      :scripts,
      :input_hooks,
      :output_hooks

    alias hooks output_hooks

    alias dependencies depends

    def initialize
      @name = nil
      @iteration = nil
      @source = Source::Null
      @version = '0.0.0'
      @maintainer = nil
      @vendor = nil
      @build_depends = {}
      @depends = {}
      @provides = {}
      @conflicts = {}
      @replaces = {}
      @steps = {}
      @scripts = {
        before_install: [],
        after_install:  [],
        before_remove:  [],
        after_remove:   []
      }
      @input_hooks = []
      @output_hooks = []
    end

    def apply_input( package )
      input_hooks.each{|h| h.call(self, package) }
      return package
    end

    def apply_output( package )
      package.name = name
      package.version = version
      package.iteration = iteration
      package.maintainer = maintainer if maintainer
      package.vendor = vendor if vendor
      scripts.each do |type, scripts|
        package.scripts[type] = scripts.join("\n") if scripts.any?
      end
      [:dependencies, :conflicts, :replaces, :provides].each do |sym|
        send(sym).each do |name, options|
          package.send(sym) << "#{name}#{options[:version]}"
        end
      end
      output_hooks.each{|h| h.call(self, package) }
      return package
    end

    alias apply apply_output

    SYNTAX_CHECK_SHELLS = ['/bin/sh','/bin/bash', '/bin/dash']

    def lint
      problems = []
      problems << "Name is empty." if name.to_s == ''
      scripts.each do |type,scripts|
        next if scripts.none?
        s = scripts.join("\n")
        if s == ''
          problems << "#{type} script is empty. This will produce broken packages."
          next
        end
        m = /\A#!([^\n]+)\n/.match(s)
        if !m
          problems << "#{type} script doesn't have a valid shebang"
          next
        end
        begin
          args = m[1].shellsplit
        rescue ArgumentError => e
          problems << "#{type} script doesn't have a valid command in shebang"
        end
        if SYNTAX_CHECK_SHELLS.include? args[0]
          sin, sout, serr, th = Open3.popen3(args[0],'-n')
          sin.write(s)
          sin.close
          if th.value.exitstatus != 0
            problems << "#{type} script is not valid #{args[0]} code: #{serr.read.chomp}"
          end
          serr.close
          sout.close
        end
      end
      return problems
    end

  end

end ; end
