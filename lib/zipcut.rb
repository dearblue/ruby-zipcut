require "gogyou"
require "zip"

module ZipCut
  module InternalExtensions
    refine Object do
      def decide_prefix
        String(self).sub(/\.zip(?:\.\d{3,})?$/i, "")
      end
    end

    refine NilClass do
      def decide_prefix
        nil
      end
    end

    refine TrueClass do
      def decide_prefix
        "[[DUMMY_PREFIX]]"
      end
    end

    refine Array do
      def decide_prefix
        case
        when empty?
          nil
        when size == 1
          String(self[0]).sub(/\.zip(?:\.\d{3,})?$/i, "")
        else
          String(self[0]).sub(/\.zip(?:\.\d{3,})?$/i, "") + "++"
        end
      end
    end

    refine Gogyou::Accessor do
      alias __buffer__ buffer__GOGYOU__
      alias __offset__ offset__GOGYOU__

      def __byteslice__(*args)
        if self.class.extensible?
          unless args.size == 1
            raise ArgumentError,
                  "wrong number of argument (given #{args.size}, expect 1)",
                  caller
          end

          size = self.class.bytesize + args[0].to_i
        else
          unless args.size == 0
            raise ArgumentError,
                  "wrong number of argument (given #{args.size}, expect 0)",
                  caller
          end

          size = self.class.bytesize
        end

        __buffer__.byteslice(__offset__, size)
      end
    end

    refine Gogyou::Accessor::BasicArray do
      def to_str(*args)
        __byteslice__(*args).unpack("Z*")[0]
      end
    end

    refine ZipCut.singleton_class do
      def decide_outdir(outdir, prefix)
        if prefix = prefix.decide_prefix
          if outdir
            File.join(outdir, prefix)
          else
            prefix.dup
          end
        else
          nil
        end
      end
    end
  end # module InternalExtensions

  using InternalExtensions

  module Extensions
    refine Zip::Entry do
      def general_name
        case
        when gp_flags[11] == 1
          name.dup.force_encoding(Encoding::UTF_8)
        when ex = extra["InfoZIPUnicodePath"]
          ex.name
        else
          name.dup
        end
      end

      def general_name=(newname)
        self.name = newname
        if newname.encoding == Encoding::UTF_8
          extra.delete("InfoZIPUnicodePath")
          self.gp_flags |= 1 << 11
        else
          if newname.ascii_only?
            extra.delete("InfoZIPUnicodePath")
            self.gp_flags |= 1 << 11
          else
            self.gp_flags &= ~(1 << 11)
            begin
              newname = newname.encode(Encoding::UTF_8)
            rescue
              ;
            else
              extra["InfoZIPUnicodePath"] = x = InfoZIPUnicodePath.new
              x.name = newname
            end
          end
        end

        newname
      end
    end
  end

  using Extensions

  def ZipCut.cut(*pathlist, outdir: nil, prefix: pathlist, mapreport: nil, &block)
    zipset = {} # { new-zip-path => zip-instance, ... }

    outdir = decide_outdir(outdir, prefix)

    pathlist.each do |path|
      begin
        Zip::InputStream.open(path, 0) do |input|
          while entry = input.get_next_entry
            ename = entry.general_name

            if ee = yield(ename, entry, path.dup)
              if zipname = ee.zipname
                zipname = zipname.sub(/(?:(?<!\A\/)|(?<!\A\w:\/))$/, ".zip") unless zipname =~ /\.zip$/i
              else
                zipname = "__TOPLEVEL__.zip"
              end

              zipname = File.join(outdir, zipname) if outdir

              raise "file exist already - #{zipname}" if File.exist?(zipname)

              mapreport&.call(zipname.freeze, ee.newpath.freeze, ename)
              if zip = zipset[zipname]
                ;
              else
                FileUtils.mkpath File.dirname zipname
                zip = zipset[zipname] = Zip::OutputStream.open(zipname + "~")
              end

              # entry情報を修正して書き込み
              # entryの実体を伸長・再圧縮させずに転写

              entry.general_name = ee.newpath
              entry.header_signature = Zip::CENTRAL_DIRECTORY_ENTRY_SIGNATURE
              zip.copy_raw_entry entry
            end
          end
        end
      #rescue
      end
    end

    zipset.each_pair do |path, zip|
      zip.close
      File.rename path + "~", path rescue $stderr.puts %(#$! (#{$!.class}))
    end

    zipset.clear

    nil
  ensure
    zipset.each_pair do |path, zip|
      tmpname = "#{path}~"
      zip.close rescue nil
      File.unlink tmpname rescue nil if File.exist?(tmpname)
    end
  end

  def ZipCut.glob_to_regexp(e)
    /\A#{glob_to_regexp!(e)}\z/
  end

  def ZipCut.glob_to_regexp!(e)
    e.gsub!(%r(
                \\(.) |
                (\*\*\/) |
                (\*) |
                \[((?:\\\\|\\\]|[^\]])*)\] |
                ([\x21-\x2f\x3a-\x3f\x5a-\x60\x7a-\x7e])
            )x) do
      case
      when $1; Regexp.escape($1)
      when $2; /(?:[^\/]*\/)*/
      when $3; /(?:[^\/]*)/
      when $4; /[#$4]/
      when $5; Regexp.escape($5)
      end
    end
  end

  class InfoZIPUnicodePath <
    Gogyou.struct {
      packed {
        uint16_le :id
        uint16_le :length
        uint8_t   :version
        uint32_le :namecheck
        char      :name, 0
      }
    }

    BasicStruct = superclass

    ID = 0x7075
    Zip::ExtraField::ID_MAP[[ID].pack("v")] = self

    def self.name
      "InfoZIPUnicodePath"
    end

    def namelength
      length - 5 # version (uint8_t) + namecheck (uint32_t)
    end

    def name
      super.to_str(namelength).force_encoding(Encoding::UTF_8)
    end

    def name=(name)
      __buffer__.resize(self.class.bytesize + name.bytesize)
      __buffer__.setbinary(self.class.bytesize, name)
      self.namecheck = Zlib.crc32(name)
      self.length = name.bytesize + 5 # version (uint8_t) + name crc32 (uint32_t)
      name
    end

    def bytesize
      super + namelength
    end

    def to_local_bin
      self.id = ID
      self.version = 1
      __buffer__.byteslice(__offset__, bytesize)
    end

    def to_c_dir_bin
      self.id = ID
      self.version = 1
      __buffer__.byteslice(__offset__, bytesize)
    end
  end

  def ZipCut.entry(zipname, newpath)
    Entry[zipname, newpath]
  end

  Entry = ::Struct.new(:zipname, :newpath)
end

def ZipCut(*args, &block)
  ZipCut.cut *args, &block
end
