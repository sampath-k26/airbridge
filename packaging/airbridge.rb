class Airbridge < Formula
  desc "AirDrop ↔ Quick Share native bridge for macOS and Android"
  homepage "https://github.com/sunkaramahesh09/airbridge"
  url "https://github.com/sunkaramahesh09/airbridge/archive/refs/tags/v2.0.0.tar.gz"
  license "GPL-3.0-only"
  head "https://github.com/sunkaramahesh09/airbridge.git", branch: "main"

  depends_on "rust" => :build
  depends_on "protobuf" => :build
  depends_on :macos

  def install
    ENV["PROTOC"] = Formula["protobuf"].opt_bin/"protoc"
    system "cargo", "install", *std_cargo_args
  end

  service do
    run [opt_bin/"airbridge"]
    log_path var/"log/airbridge.log"
    error_log_path var/"log/airbridge.err"
  end

  test do
    system "#{bin}/airbridge", "--version"
  end
end
