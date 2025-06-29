# frozen_string_literal: true

require_relative "helper"

class TestOutOfBandServer < PumaTest
  parallelize_me!

  def setup
    @ios = []
    @server = nil
    @oob_finished = ConditionVariable.new
    @app_finished = ConditionVariable.new
  end

  def teardown
    @oob_finished.broadcast
    @app_finished.broadcast
    @server&.stop true

    @ios.each do |io|
      begin
        io.close if io.is_a?(IO) && !io.closed?
      rescue
      ensure
        io = nil
      end
    end
  end

  def new_connection
    TCPSocket.new('127.0.0.1', @port).tap {|s| @ios << s}
  rescue IOError
    Puma::Util.purge_interrupt_queue
    retry
  end

  def send_http(req)
    new_connection << req
  end

  def send_http_and_read(req)
    send_http(req).read
  end

  def oob_server(**options)
    @request_count = 0
    @oob_count = 0
    in_oob = Mutex.new
    @mutex = Mutex.new
    oob_wait = options.delete(:oob_wait)
    oob = -> do
      in_oob.synchronize do
        @mutex.synchronize do
          @oob_count += 1
          @oob_finished.signal
          @oob_finished.wait(@mutex, 1) if oob_wait
        end
      end
    end
    app_wait = options.delete(:app_wait)
    app = ->(_) do
      raise 'OOB conflict' if in_oob.locked?
      @mutex.synchronize do
        @request_count += 1
        @app_finished.signal
        @app_finished.wait(@mutex, 1) if app_wait
      end
      [200, {}, [""]]
    end

    options[:min_threads] ||= 1
    options[:max_threads] ||= 1
    options[:log_writer]  ||= Puma::LogWriter.strings

    @server = Puma::Server.new app, nil, out_of_band: [oob], **options
    @port = (@server.add_tcp_listener '127.0.0.1', 0).addr[1]
    @server.run
    sleep 0.15 if Puma.jruby?
  end

  # Sequential requests should trigger out_of_band after every request.
  def test_sequential
    n = 100
    oob_server
    n.times do
      @mutex.synchronize do
        send_http "GET / HTTP/1.0\r\n\r\n"
        @oob_finished.wait(@mutex, 1)
      end
    end
    assert_equal n, @request_count
    assert_equal n, @oob_count
  end

  # Stream of requests on concurrent connections should trigger
  # out_of_band hooks only once after the final request.
  def test_stream
    oob_server app_wait: true, max_threads: 2
    n = 100
    Array.new(n) {send_http("GET / HTTP/1.0\r\n\r\n")}
    Thread.pass until @request_count == n
    @mutex.synchronize do
      @app_finished.signal
      @oob_finished.wait(@mutex, 1)
    end
    assert_equal n, @request_count
    assert_equal 1, @oob_count
  end

  # New requests should not get processed while OOB is running.
  def test_request_overlapping_hook
    oob_server oob_wait: true, max_threads: 2

    # Establish connection for Req2 before OOB
    req2 = new_connection
    sleep 0.01

    @mutex.synchronize do
      send_http "GET / HTTP/1.0\r\n\r\n"
      @oob_finished.wait(@mutex) # enter OOB

      # Send Req2
      req2 << "GET / HTTP/1.0\r\n\r\n"
      # If Req2 is processed now it raises 'OOB Conflict' in the response.
      sleep 0.01

      @oob_finished.signal # exit OOB
      # Req2 should be processed now.
      @oob_finished.wait(@mutex, 1) # enter OOB
      @oob_finished.signal # exit OOB
    end

    refute_match(/OOB conflict/, req2.read)
  end

  # Partial requests should not trigger OOB.
  def test_partial_request
    oob_server
    new_connection.close
    sleep 0.01
    assert_equal 0, @oob_count
  end

  # OOB should be triggered following a completed request
  # concurrent with other partial requests.
  def test_partial_concurrent
    oob_server max_threads: 2
    @mutex.synchronize do
      send_http("GET / HTTP/1.0\r\n\r\n")
      100.times {new_connection.close}
      @oob_finished.wait(@mutex, 1)
    end
    assert_equal 1, @oob_count
  end

  # OOB should block new connections from being accepted.
  def test_blocks_new_connection
    oob_server oob_wait: true, max_threads: 2
    @mutex.synchronize do
      send_http("GET / HTTP/1.0\r\n\r\n")
      @oob_finished.wait(@mutex)
    end
    accepted = false
    io = @server.binder.ios.last
    io.stub(:accept_nonblock, -> {accepted = true; new_connection}) do
      new_connection.close
      sleep 0.01
    end
    refute accepted, 'New connection accepted during out of band'
  end
end
