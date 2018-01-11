if File.read("README.md", 4096) =~ /^\s*\*\s*version:{1,2}\s*(.+)/i
  version = $1
else
  raise "バージョン情報が README.md に見つかりません"
end


GEMSTUB = Gem::Specification.new do |s|
  s.name = "zipcut"
  s.version = version
  s.summary = "entry manipulator for zip archive"
  s.description = <<-EOS
(EXPERIMENTAL! YOU MAY LOST DATA!)
zip 書庫ファイルをエントリ単位で分割します。
副次的な機能として、複数の zip 書庫を一つにまとめたり、エントリ名の変更などを行うことが出来ます。
  EOS
  s.homepage = "https://github.com/dearblue/ruby-zipcut"
  s.license = "BSD-2-Clause"
  s.author = "dearblue"
  s.email = "dearblue@users.noreply.github.com"

  s.add_runtime_dependency "rubyzip", ">= 1.2.1", "~> 1.2"
  s.add_runtime_dependency "gogyou", ">= 0.2.5", "~> 0.2"
  s.add_development_dependency "rake", "~> 0"
end
