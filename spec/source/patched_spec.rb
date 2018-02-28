require 'fpm/fry/source/patched'
require 'digest'
describe FPM::Fry::Source::Patched do

  let(:patches){
    [ File.expand_path(File.join(File.dirname(__FILE__),'..','data','patch.diff')) ]
  }

  context '#build_cache' do

    let(:tmpdir){
      Dir.mktmpdir('fpm-fry')
    }

    let(:cache){
      c = double('cache')
      allow(c).to receive(:tar_io){
        sio = StringIO.new
        tw = ::Gem::Package::TarWriter.new(sio)
        tw.add_file('World',0755) do |io|
          io.write("Hello\n")
        end
        sio.rewind
        sio
      }
      allow(c).to receive(:cachekey){
        Digest::SHA1.hexdigest("World\x00Hello\n")
      }
      c
    }

    let(:source){
      s = double('source')
      allow(s).to receive(:logger){ logger }
      allow(s).to receive(:build_cache){|_| cache }
      s
    }

    after do
      FileUtils.rm_rf(tmpdir)
    end

    it "just passes if no patch is present" do
      src = FPM::Fry::Source::Patched.new(source)
      cache = src.build_cache(tmpdir)
      io = cache.tar_io
      begin
        rd = FPM::Fry::Tar::Reader.new(IOFilter.new(io))
        files = Hash[ rd.each.map{|e| [e.header.name, e.read] } ]
        expect(files.size).to eq(2)
        expect(files['./World']).to eq "Hello\n"
      ensure
        io.close
      end
    end

    it "applies given patches" do
      src = FPM::Fry::Source::Patched.new(source, patches: patches )
      cache = src.build_cache(tmpdir)
      io = cache.tar_io
      begin
        rd = FPM::Fry::Tar::Reader.new(IOFilter.new(io))
        files = Hash[ rd.each.map{|e| [e.header.name, e.read] } ]
        expect(files.size).to eq(2)
        expect(files['./World']).to eq "Olla\n"
      ensure
        io.close
      end
    end

    it "fails if patch fails" do
      src = FPM::Fry::Source::Patched.new(FPM::Fry::Source::Null, patches: patches )
      expect{
        cache = src.build_cache(tmpdir)
        cache.tar_io
      }.to raise_error(FPM::Fry::Source::CacheFailed){|e|
        expect(e.data).to include(
          patch: %r!/spec/data/patch.diff\z!,
          exitstatus: 1,
          command: Array
        )
      }
    end

    it "applies given patches with chdir" do
      allow(cache).to receive(:tar_io){
        sio = StringIO.new
        tw = ::Gem::Package::TarWriter.new(sio)
        tw.add_file('World',0755) do |io|
          io.write("Hello\n")
        end
        tw.add_file('foo/World',0755) do |io|
          io.write("Hello\n")
        end
        sio.rewind
        sio
      }
      src = FPM::Fry::Source::Patched.new(source,
                                              patches: [
                                                file: patches[0], chdir: 'foo'
                                              ] )
      cache = src.build_cache(tmpdir)
      io = cache.tar_io
      begin
        rd = FPM::Fry::Tar::Reader.new(IOFilter.new(io))
        files = Hash[ rd.each.map{|e| [e.header.name, e.read] } ]
        expect(files.size).to eq(4)
        expect(files['./World']).to eq "Hello\n"
        expect(files['./foo/World']).to eq "Olla\n"
      ensure
        io.close
      end
    end

    context "with a source supporting #prefix" do
      before(:each) do
        allow(cache).to receive(:tar_io){
          sio = StringIO.new
          tw = ::Gem::Package::TarWriter.new(sio)
          tw.add_file('World',0755) do |io|
            io.write("Hello\n")
          end
          tw.add_file('foo/World',0755) do |io|
            io.write("Hello\n")
          end
          sio.rewind
          sio
        }
        allow(cache).to receive(:prefix).and_return('foo')
      end

      it "uses the prefix as chdir" do
        src = FPM::Fry::Source::Patched.new(source,
                                                patches: [
                                                  file: patches[0]
                                                ] )
        cache = src.build_cache(tmpdir)
        io = cache.tar_io
        begin
          rd = Gem::Package::TarReader.new(IOFilter.new(io))
          files = Hash[ rd.each.map{|e| [e.header.name, e.read] } ]
          expect(files.size).to eq(4)
          expect(files['./World']).to eq "Hello\n"
          expect(files['./foo/World']).to eq "Olla\n"
        ensure
          io.close
        end
      end

      it "tells the user to remove the chdir if it's not needed" do
        src = FPM::Fry::Source::Patched.new(source,
                                                patches: [
                                                  file: patches[0], chdir: 'foo'
                                                ] )
        expect(logger).to receive(:hint).with(/\AYou can remove the chdir:/, documentation: /Source-patching#chdir\z/)
        cache = src.build_cache(tmpdir)
        cache.tar_io
      end

      it "tells the user to remove the chdir if it's not needed even when the cache is current" do
        src = FPM::Fry::Source::Patched.new(source,
                                                patches: [
                                                  file: patches[0], chdir: 'foo'
                                                ] )
        expect(logger).to receive(:hint).with(/\AYou can remove the chdir:/, documentation: /Source-patching#chdir\z/)
        cache = src.build_cache(tmpdir)
        Dir.mkdir(cache.unpacked_tmpdir)
        cache.tar_io
      end

    end

    it "returns the correct cachekey" do
      src = FPM::Fry::Source::Patched.new(source, patches: patches )
      cache = src.build_cache(tmpdir)
      expect( cache.cachekey ).to eq Digest::SHA2.hexdigest(cache.inner.cachekey + "\x00" + IO.read(src.patches[0][:file]) + "\x00")
    end

    it "doesn't create colliding caches" do
      src  = FPM::Fry::Source::Patched.new(source, patches: patches )
      cache = src.build_cache(tmpdir)
      io = cache.tar_io
      begin
        rd = FPM::Fry::Tar::Reader.new(IOFilter.new(io))
        files = Hash[ rd.each.map{|e| [e.header.name, e.read] } ]
        expect(files.size).to eq(2)
        expect(files['./World']).to eq "Olla\n"
      ensure
        io.close
      end

      src = FPM::Fry::Source::Patched.new(source, patches: [File.expand_path(File.join(File.dirname(__FILE__),'..','data','patch2.diff'))] )
      cache = src.build_cache(tmpdir)
      io = cache.tar_io
      begin
        rd = FPM::Fry::Tar::Reader.new(IOFilter.new(io))
        files = Hash[ rd.each.map{|e| [e.header.name, e.read] } ]
        expect(files.size).to eq(2)
        expect(files['./World']).to eq "Ciao\n"
      ensure
        io.close
      end

      src  = FPM::Fry::Source::Patched.new(source, patches: patches )
      cache = src.build_cache(tmpdir)
      io = cache.tar_io
      begin
        rd = FPM::Fry::Tar::Reader.new(IOFilter.new(io))
        files = Hash[ rd.each.map{|e| [e.header.name, e.read] } ]
        expect(files.size).to eq(2)
        expect(files['./World']).to eq "Olla\n"
      ensure
        io.close
      end
    end

    it "removes existing workdirs" do
      src = FPM::Fry::Source::Patched.new(source, patches: patches )
      cache = src.build_cache(tmpdir)
      workdir = cache.unpacked_tmpdir + '.tmp'
      canary  =  File.join( workdir , 'cananry.file')
      FileUtils.mkdir( workdir )
      IO.write( canary , 'foo' )
      cache.send(:update!)
      expect( File.exist? canary ).to be false
    end

    context 'with #copy_to' do
      before do
        allow(cache).to receive(:copy_to) do |dst|
          File.open(File.join(dst,'World'),'w',0755) do |f|
            f.write("Hello\n")
          end
        end
        expect(cache).not_to receive(:tar_io)
      end

      it "applies given patches" do
        src = FPM::Fry::Source::Patched.new(source, patches: patches )
        cache = src.build_cache(tmpdir)
        io = cache.tar_io
        begin
          rd = FPM::Fry::Tar::Reader.new(IOFilter.new(io))
          files = Hash[ rd.each.map{|e| [e.header.name, e.read] } ]
          expect(files.size).to eq(2)
          expect(files['./World']).to eq "Olla\n"
        ensure
          io.close
        end
      end

    end

  end

  context '#decorate' do

    let(:source){ double("source") }

    it 'just passes if nothing is configured' do
      expect(FPM::Fry::Source::Patched.decorate({}){source}).to be source
    end

    it 'just passes if the patches list is empty' do
      expect(FPM::Fry::Source::Patched.decorate(patches: []){source}).to be source
    end
    it 'decorates if the list is not empty' do
      expect(FPM::Fry::Source::Patched.decorate(patches: patches){source}).to be_a FPM::Fry::Source::Patched
    end
    it 'passes the patch file list' do
      expect(FPM::Fry::Source::Patched.decorate(patches: patches){source}.patches).to eq [{file:patches[0]}]
    end
  end

  describe '#prefix' do

    let(:tmpdir){
      Dir.mktmpdir('fpm-fry')
    }

    let(:source_cache){
      double("source_cache")
    }

    let(:source){
      s = double("source")
      allow(s).to receive(:build_cache){ source_cache }
      s
    }

    it 'forward prefix to inner cache' do
      outer = FPM::Fry::Source::Patched.new(source)
      expect(source_cache).to receive(:prefix).and_return("an/arbitrary/prefix")
      expect(outer.build_cache(tmpdir).prefix).to eq "an/arbitrary/prefix"
    end

  end
end
