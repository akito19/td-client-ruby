require 'spec_helper'
require 'td/client/api'
require 'logger'
require 'webrick'
require 'webrick/https'

# Workaround for https://github.com/jruby/jruby-openssl/issues/78
# With recent JRuby + jruby-openssl, X509CRL#extentions_to_text causes
# StringIndexOOBException when we try to dump SSL Server Certificate.
# when one of extensions has "" as value.
# This hack is from httpclient https://github.com/nahi/httpclient/blob/master/lib/httpclient/util.rb#L27-L46
if defined? JRUBY_VERSION
  require 'openssl'
  require 'java'
  module OpenSSL
    module X509
      class Certificate
        java_import 'java.security.cert.Certificate'
        java_import 'java.security.cert.CertificateFactory'
        java_import 'java.io.ByteArrayInputStream'
        def to_text
          cf = CertificateFactory.getInstance('X.509')
          cf.generateCertificate(ByteArrayInputStream.new(self.to_der.to_java_bytes)).toString
        end
      end
    end
  end
end

describe 'API SSL connection' do
  DIR = File.dirname(File.expand_path(__FILE__))

  after :each do
    @server.shutdown if @server
  end

  it 'should fail to connect SSLv3 only server' do
    @server = setup_server(:SSLv3)
    api = API.new(nil, :endpoint => "https://localhost:#{@serverport}", :retry_post_requests => false)
    api.ssl_ca_file = File.join(DIR, 'ca-all.cert')
    expect {
      api.delete_database('no_such_database')
    }.to raise_error OpenSSL::SSL::SSLError
  end

  it 'should success to connect TLSv1 only server' do
    @server = setup_server(:TLSv1)
    api = API.new(nil, :endpoint => "https://localhost:#{@serverport}", :retry_post_requests => false)
    api.ssl_ca_file = File.join(DIR, 'ca-all.cert')
    expect {
      api.delete_database('no_such_database')
    }.to raise_error TreasureData::NotFoundError
  end

  def setup_server(ssl_version)
    logger = Logger.new(STDERR)
    logger.level = Logger::Severity::FATAL  # avoid logging SSLError (ERROR level)
    @server = WEBrick::HTTPServer.new(
      :BindAddress => "localhost",
      :Logger => logger,
      :Port => 0,
      :AccessLog => [],
      :DocumentRoot => '.',
      :SSLEnable => true,
      :SSLCACertificateFile => File.join(DIR, 'ca.cert'),
      :SSLCertificate => cert('server.cert'),
      :SSLPrivateKey => key('server.key')
    )
    @serverport = @server.config[:Port]
    @server.mount(
      '/hello',
      WEBrick::HTTPServlet::ProcHandler.new(method(:do_hello).to_proc)
    )
    begin
      puts ">>> SSL_CONTEXT: #{@server.ssl_context.class}"
      @server.ssl_context.ssl_version = ssl_version
    rescue ArgumentError => e
      pending 'Skip tests'
      # puts ">>> ArgumentError >>>", e.backtrace
      # raise
    end
    @server_thread = start_server_thread(@server)
    return @server
  end

  def do_hello(req, res)
    res['content-type'] = 'text/html'
    res.body = "hello"
  end

  def start_server_thread(server)
    t = Thread.new {
      Thread.current.abort_on_exception = true
      server.start
    }
    while server.status != :Running
      sleep 0.1
      unless t.alive?
        t.join
        raise
      end
    end
    t
  end

  def cert(filename)
    OpenSSL::X509::Certificate.new(File.read(File.join(DIR, filename)))
  end

  def key(filename)
    OpenSSL::PKey::RSA.new(File.read(File.join(DIR, filename)))
  end
end
