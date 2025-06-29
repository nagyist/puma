# frozen_string_literal: true

# Copyright (c) 2011 Evan Phoenix
# Copyright (c) 2005 Zed A. Shaw

require_relative "helper"
require_relative "helpers/integration"
require "digest"

require "puma/puma_http11"

class Http11ParserTest < TestIntegration

  parallelize_me!

  def test_parse_simple
    parser = Puma::HttpParser.new
    req = {}
    http = "GET /?a=1 HTTP/1.1\r\n\r\n"
    nread = parser.execute(req, http, 0)

    assert nread == http.length, "Failed to parse the full HTTP request"
    assert parser.finished?, "Parser didn't finish"
    assert !parser.error?, "Parser had error"
    assert nread == parser.nread, "Number read returned from execute does not match"

    assert_equal '/', req['REQUEST_PATH']
    assert_equal 'HTTP/1.1', req['SERVER_PROTOCOL']
    assert_equal '/?a=1', req['REQUEST_URI']
    assert_equal 'GET', req['REQUEST_METHOD']
    assert_nil req['FRAGMENT']
    assert_equal "a=1", req['QUERY_STRING']

    parser.reset
    assert parser.nread == 0, "Number read after reset should be 0"
  end

  def test_parse_escaping_in_query
    parser = Puma::HttpParser.new
    req = {}
    http = "GET /admin/users?search=%27%%27 HTTP/1.1\r\n\r\n"
    nread = parser.execute(req, http, 0)

    assert nread == http.length, "Failed to parse the full HTTP request"
    assert parser.finished?, "Parser didn't finish"
    assert !parser.error?, "Parser had error"
    assert nread == parser.nread, "Number read returned from execute does not match"

    assert_equal '/admin/users?search=%27%%27', req['REQUEST_URI']
    assert_equal "search=%27%%27", req['QUERY_STRING']

    parser.reset
    assert parser.nread == 0, "Number read after reset should be 0"
  end

  def test_parse_absolute_uri
    parser = Puma::HttpParser.new
    req = {}
    http = "GET http://192.168.1.96:3000/api/v1/matches/test?1=1 HTTP/1.1\r\n\r\n"
    nread = parser.execute(req, http, 0)

    assert nread == http.length, "Failed to parse the full HTTP request"
    assert parser.finished?, "Parser didn't finish"
    assert !parser.error?, "Parser had error"
    assert nread == parser.nread, "Number read returned from execute does not match"

    assert_equal "GET", req['REQUEST_METHOD']
    assert_equal 'http://192.168.1.96:3000/api/v1/matches/test?1=1', req['REQUEST_URI']
    assert_equal 'HTTP/1.1', req['SERVER_PROTOCOL']

    assert_nil req['REQUEST_PATH']
    assert_nil req['FRAGMENT']
    assert_nil req['QUERY_STRING']

    parser.reset
    assert parser.nread == 0, "Number read after reset should be 0"

  end

  def test_parse_dumbfuck_headers
    parser = Puma::HttpParser.new
    req = {}
    should_be_good = "GET / HTTP/1.1\r\naaaaaaaaaaaaa:++++++++++\r\n\r\n"
    nread = parser.execute(req, should_be_good, 0)
    assert_equal should_be_good.length, nread
    assert parser.finished?
    assert !parser.error?
  end

  def test_parse_error
    parser = Puma::HttpParser.new
    req = {}
    bad_http = "GET / SsUTF/1.1"

    error = false
    begin
      parser.execute(req, bad_http, 0)
    rescue
      error = true
    end

    assert error, "failed to throw exception"
    assert !parser.finished?, "Parser shouldn't be finished"
    assert parser.error?, "Parser SHOULD have error"
  end

  def test_fragment_in_uri
    parser = Puma::HttpParser.new
    req = {}
    get = "GET /forums/1/topics/2375?page=1#posts-17408 HTTP/1.1\r\n\r\n"

    parser.execute(req, get, 0)

    assert parser.finished?
    assert_equal '/forums/1/topics/2375?page=1', req['REQUEST_URI']
    assert_equal 'posts-17408', req['FRAGMENT']
  end

  def test_semicolon_in_path
    parser = Puma::HttpParser.new
    req = {}
    get = "GET /forums/1/path;stillpath/2375?page=1 HTTP/1.1\r\n\r\n"

    parser.execute(req, get, 0)

    assert parser.finished?
    assert_equal '/forums/1/path;stillpath/2375?page=1', req['REQUEST_URI']
    assert_equal '/forums/1/path;stillpath/2375', req['REQUEST_PATH']
  end

  # lame random garbage maker
  def rand_data(min, max, readable=true)
    count = min + ((rand(max)+1) *10).to_i
    res = count.to_s + "/"

    if readable
      res << Digest(:SHA1).hexdigest(rand(count * 100).to_s) * (count / 40)
    else
      res << Digest(:SHA1).digest(rand(count * 100).to_s) * (count / 20)
    end

    res
  end

  def test_get_const_length
    skip_unless :jruby

    envs = %w[PUMA_REQUEST_URI_MAX_LENGTH PUMA_REQUEST_PATH_MAX_LENGTH PUMA_QUERY_STRING_MAX_LENGTH]
    default_exp = [1024 * 12, 8192, 10 * 1024]
    tests = [{ envs: %w[60000 61000 62000], exp: [60000, 61000, 62000], error_indexes: [] },
             { envs: ['', 'abc', nil], exp: default_exp, error_indexes: [1] },
             { envs: %w[-4000 0 3000.45], exp: default_exp, error_indexes: [0, 1, 2] }]
    cli_config = <<~CONFIG
        app do |_|
          require 'json'
          [200, {}, [{ MAX_REQUEST_URI_LENGTH: org.jruby.puma.Http11::MAX_REQUEST_URI_LENGTH,
                       MAX_REQUEST_PATH_LENGTH: org.jruby.puma.Http11::MAX_REQUEST_PATH_LENGTH,
                       MAX_QUERY_STRING_LENGTH: org.jruby.puma.Http11::MAX_QUERY_STRING_LENGTH,
                       MAX_REQUEST_URI_LENGTH_ERR: org.jruby.puma.Http11::MAX_REQUEST_URI_LENGTH_ERR,
                       MAX_REQUEST_PATH_LENGTH_ERR: org.jruby.puma.Http11::MAX_REQUEST_PATH_LENGTH_ERR,
                       MAX_QUERY_STRING_LENGTH_ERR: org.jruby.puma.Http11::MAX_QUERY_STRING_LENGTH_ERR }.to_json]]
        end
    CONFIG

    tests.each do |conf|
      cli_server 'test/rackup/hello.ru',
                      env: {envs[0]  => conf[:envs][0], envs[1] => conf[:envs][1], envs[2] => conf[:envs][2]},
                      merge_err: true,
                      config: cli_config
      result = JSON.parse read_body(connect)

      assert_equal conf[:exp][0], result['MAX_REQUEST_URI_LENGTH']
      assert_equal conf[:exp][1], result['MAX_REQUEST_PATH_LENGTH']
      assert_equal conf[:exp][2], result['MAX_QUERY_STRING_LENGTH']

      assert_includes result['MAX_REQUEST_URI_LENGTH_ERR'], "longer than the #{conf[:exp][0]} allowed length"
      assert_includes result['MAX_REQUEST_PATH_LENGTH_ERR'], "longer than the #{conf[:exp][1]} allowed length"
      assert_includes result['MAX_QUERY_STRING_LENGTH_ERR'], "longer than the #{conf[:exp][2]} allowed length"

      conf[:error_indexes].each do |index|
        assert_includes @server_log, "The value #{conf[:envs][index]} for #{envs[index]} is invalid. "\
          "Using default value #{default_exp[index]} instead"
      end

      stop_server
     end
  end

  def test_max_uri_path_length
    parser = Puma::HttpParser.new
    req = {}

    # Support URI path length to a max of 8192
    path = "/" + rand_data(7000, 100)
    http = "GET #{path} HTTP/1.1\r\n\r\n"
    parser.execute(req, http, 0)
    assert_equal path, req['REQUEST_PATH']
    parser.reset

    # Raise exception if URI path length > 8192
    path = "/" + rand_data(9000, 100)
    http = "GET #{path} HTTP/1.1\r\n\r\n"
    assert_raises Puma::HttpParserError do
      parser.execute(req, http, 0)
      parser.reset
    end
  end

  def test_horrible_queries
    parser = Puma::HttpParser.new

    # then that large header names are caught
    10.times do |c|
      get = "GET /#{rand_data(10,120)} HTTP/1.1\r\nX-#{rand_data(1024, 1024+(c*1024))}: Test\r\n\r\n"
      assert_raises Puma::HttpParserError do
        parser.execute({}, get, 0)
        parser.reset
      end
    end

    # then that large mangled field values are caught
    10.times do |c|
      get = "GET /#{rand_data(10,120)} HTTP/1.1\r\nX-Test: #{rand_data(1024, 1024+(c*1024), false)}\r\n\r\n"
      assert_raises Puma::HttpParserError do
        parser.execute({}, get, 0)
        parser.reset
      end
    end

    # then large headers are rejected too
    get  = "GET /#{rand_data(10,120)} HTTP/1.1\r\n"
    get += "X-Test: test\r\n" * (80 * 1024)
    assert_raises Puma::HttpParserError do
      parser.execute({}, get, 0)
      parser.reset
    end

    # finally just that random garbage gets blocked all the time
    10.times do |c|
      get = "GET #{rand_data(1024, 1024+(c*1024), false)} #{rand_data(1024, 1024+(c*1024), false)}\r\n\r\n"
      assert_raises Puma::HttpParserError do
        parser.execute({}, get, 0)
        parser.reset
      end
    end
  end

  def test_trims_whitespace_from_headers
    parser = Puma::HttpParser.new
    req = {}
    http = "GET / HTTP/1.1\r\nX-Strip-Me: Strip This       \r\n\r\n"

    parser.execute(req, http, 0)

    assert_equal "Strip This", req["HTTP_X_STRIP_ME"]
  end

  def test_newline_smuggler
    parser = Puma::HttpParser.new
    req = {}
    http = "GET / HTTP/1.1\r\nHost: localhost:8080\r\nDummy: x\nDummy2: y\r\n\r\n"

    parser.execute(req, http, 0) rescue nil # We test the raise elsewhere.

    assert parser.error?, "Parser SHOULD have error"
  end

  def test_newline_smuggler_two
    parser = Puma::HttpParser.new
    req = {}
    http = "GET / HTTP/1.1\r\nHost: localhost:8080\r\nDummy: x\r\nDummy: y\nDummy2: z\r\n\r\n"

    parser.execute(req, http, 0) rescue nil

    assert parser.error?, "Parser SHOULD have error"
  end

  def test_htab_in_header_val
    parser = Puma::HttpParser.new
    req = {}
    http = "GET / HTTP/1.1\r\nHost: localhost:8080\r\nDummy: Valid\tValue\r\n\r\n"

    parser.execute(req, http, 0)

    assert_equal "Valid\tValue", req['HTTP_DUMMY']
  end
end
