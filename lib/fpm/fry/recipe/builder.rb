require 'fpm/fry/recipe'
require 'forwardable'
module FPM::Fry
  class Recipe

    class NotFound < StandardError
    end

    class PackageBuilder < Struct.new(:variables, :package_recipe)

      attr :logger

      def initialize( variables, recipe = PackageRecipe.new, options = {})
        super(variables, recipe)
        @logger = options.fetch(:logger){ Cabin::Channel.get }
      end

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

      def depends( name , options = {} )
        name, options = parse_package(name, options)
        package_recipe.depends[name] = options
      end

      def conflicts( name , options = {} )
        name, options = parse_package(name, options)
        package_recipe.conflicts[name] = options
      end

      def provides( name , options = {} )
        name, options = parse_package(name, options)
        package_recipe.provides[name] = options
      end

      def replaces( name , options = {} )
        name, options = parse_package(name, options)
        package_recipe.replaces[name] = options
      end

      def files( pattern )
        package_recipe.files << pattern
      end

      def plugin(name, *args, &block)
        logger.debug('Loading Plugin', name: name, args: args, block: block, load_path: $LOAD_PATH)
        if name =~ /\A\./
          require name
        else
          require File.join('fpm/fry/plugin',name)
        end
        module_name = File.basename(name,'.rb').gsub(/(?:\A|_)([a-z])/){ $1.upcase }
        mod = FPM::Fry::Plugin.const_get(module_name)
        if mod.respond_to? :apply
          mod.apply(self, *args, &block)
        else
          extend(mod)
        end
      end

      def script(type, value = Not)
        if value != Not
          package_recipe.scripts[type] << value
        end
        return package_recipe.scripts[type]
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

      def output_hooks
        package_recipe.output_hooks
      end

    protected

      def parse_package( name, options = {} )
        if options.kind_of? String
          options = {version: options}
        end
        case(v = options[:version])
        when String
          if v =~ /\A(<=|<<|>=|>>|<>|=|>|<)(\s*)/
            options[:version] = ' ' + $1 + ' ' + $'
          else
            options[:version] = ' = ' + v
          end
        end
        return name, options
      end


      Not = Module.new
      def get_or_set(name, value = Not)
        if value == Not
          return package_recipe.instance_variable_get(name)
        else
          return package_recipe.instance_variable_set(name, value)
        end
      end

    end

    class Builder < PackageBuilder

      attr :recipe

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
        @recipe = recipe
        super(variables, recipe.packages[0], options = {})
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

      def source( url , options = {} )
        options = options.merge(logger: logger)
        source = Source::Patched.decorate(options) do |options|
          guess_source(url,options).new(url, options)
        end
        recipe.source = source
      end

      def run(*args)
        if args.first.kind_of? Hash
          options = args.shift
        else
          options = {}
        end
        command = args.shift
        name = options.fetch(:name){ [command,*args].select{|c| c[0] != '-' }.join(' ') }
        bash( name, Shellwords.join([command, *args]) )
      end

      def bash( name = nil, code )
        if name
          recipe.steps << Recipe::Step.new(name, code)
        else
          recipe.steps << code.to_s
        end
      end

      def build_depends( name , options = {} )
        name, options = parse_package(name, options)
        recipe.build_depends[name] = options
      end

      def input_hooks
        recipe.input_hooks
      end

      def package(name, &block)
        pr = PackageRecipe.new
        pr.name = name
        pr.version = package_recipe.version
        pr.iteration = package_recipe.iteration
        recipe.packages << pr
        PackageBuilder.new(variables, pr).instance_eval(&block)
      end

    protected

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

    end
  end
end
