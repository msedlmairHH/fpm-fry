require 'fpm/dockery/recipe'
require 'fpm/package'
describe FPM::Dockery::Recipe do

  def build(vars ={}, str)
    b = FPM::Dockery::Recipe::Builder.new(vars)
    b.instance_eval(str)
    return b.recipe
  end

  let(:package) do
    p = FPM::Package.new
    subject.apply(p)
    p
  end

  context "basic attributes" do
    subject do
      build <<RECIPE
name "foo"
version "0.2.1"
RECIPE
    end

    it 'has a name' do
      expect(subject.name).to eq "foo"
    end

    it 'has a version' do
      expect(subject.version).to eq '0.2.1'
    end

    it 'applies the name' do
      expect(package.name).to eq 'foo'
    end

    it 'applies the version' do
      expect(package.version).to eq '0.2.1'
    end
  end

  context "scripts" do
    subject do
      build <<RECIPE
before_install "before install"
RECIPE
    end

    it 'support setting before_install' do
      expect(package.scripts).to eq({before_install: "before install"})
    end
  end

  context "relations" do
    subject do
      build <<RECIPE
depends "foo"
depends "bar", ">=0.0.1"
conflicts "zub"
provides "fub"
replaces "zof"
RECIPE
    end

    it 'has correct dependencies' do
      expect(package.dependencies).to eq(['foo','bar>=0.0.1'])
    end

    it 'has correct conflicts' do
      expect(package.conflicts).to eq(['zub'])
    end

    it 'has correct provides' do
      expect(package.provides).to eq(['fub'])
    end

    it 'has correct replaces' do
      expect(package.replaces).to eq(['zof'])
    end
  end

  context "plugins" do
    subject do
      build( {distribution: "ubuntu"}, <<RECIPE)
plugin "platforms"

platforms [:ubuntu] do
  depends "ubuntu"
end

platforms [:centos] do
  depends "centos"
end
RECIPE
    end

    it 'works' do
      expect(package.dependencies).to eq(['ubuntu'])
    end
  end

  context 'source type guessing' do

    {
      'http://foo.bar/baz.tar.gz' => FPM::Dockery::Source::Package,
      'http://foo.bar/baz.git'    => FPM::Dockery::Source::Git,
      'git@foo.bar:baz/baz.git'   => FPM::Dockery::Source::Git,
      '/foo/bar'                  => FPM::Dockery::Source::Dir,
      './foo/bar'                 => FPM::Dockery::Source::Dir,
      'file://foo/bar'            => FPM::Dockery::Source::Dir
    }.each do |url, klass|
      it "map #{url} to #{klass}" do
        b = FPM::Dockery::Recipe::Builder.new({})
        expect( b.send(:guess_source,url) ).to eq klass
      end
    end
  end

  describe '#load_file' do
    let(:tmpdir){
      Dir.mktmpdir("fpm-dockery")
    }
    after(:each) do
      FileUtils.rm_rf(tmpdir)
    end

    context 'working directory' do

      it "is switched to the recipes basedir" do
        IO.write(File.join(tmpdir,'recipe.rb'),'variables[:probe] << Dir.pwd')
        builder = FPM::Dockery::Recipe::Builder.new(probe: [])
        builder.load_file(File.join(tmpdir,'recipe.rb'))
        expect(builder.variables[:probe][0]).to eq(tmpdir)
      end

    end
  end

  describe '#lint' do

    context 'with broken scripts' do
      subject do
        build( {distribution: "ubuntu"}, <<RECIPE)
name 'foo'
after_install '#!/bin/bash
if [ $1 = "configure" ] ; then
  broken'
RECIPE
      end

      it 'reports the scripts' do
        expect(subject.lint).to eq ["after_install script is not valid bash code: bash: line 4: syntax error: unexpected end of file"]
      end

    end
  end
end

