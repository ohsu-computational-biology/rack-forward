require 'rack/forward/version'
require 'rack/utils'
require 'net/http'

module Rack
  class Forward
    HTTP_METHODS = %w[GET HEAD PUT POST DELETE OPTIONS PATCH].freeze

    def initialize(app, options = {}, &block)
      self.class.send(:define_method, :uri_for, &block)
      @app = app
      @proxied_cookies = options[:cookies] || []
      @domain = options[:domain] || nil
      @secure = options[:secure] || false
      @timeout = options[:timeout] || 5
      @custom_headers = options[:custom_headers] || []
    end

    def call(env)
      req    = Rack::Request.new(env)
      uri    = uri_for(req)
      method = req.request_method.upcase

      return @app.call(env) unless uri && HTTP_METHODS.include?(method)

      sub_request = Net::HTTP.const_get(method.capitalize).new("#{uri.path}#{'?' if uri.query}#{uri.query}")

      if sub_request.request_body_permitted? && req.body
        sub_request.body_stream = req.body
        sub_request.content_length = req.content_length
        sub_request.content_type = req.content_type
      end

      sub_request['X-Identity-Service-Key'] = req.env['HTTP_X_IDENTITY_SERVICE_KEY']
      sub_request['X-Forwarded-For'] = (req.env['X-Forwarded-For'].to_s.split(/, */) + [req.env['REMOTE_ADDR']]).join(', ')
      sub_request['Accept'] = req.env['HTTP_ACCEPT']
      sub_request['Accept-Encoding'] = req.accept_encoding
      sub_request['Authorization'] = req.env['HTTP_AUTHORIZATION']
      sub_request['Access-Control-Allow-Origin'] = req.env['ACCESS_CONTROL_ALLOW_ORIGIN']
      sub_request['Cookie']  = req.env['HTTP_COOKIE']
      sub_request['Referer'] = req.referer
      @custom_headers.each do |header|
        sub_request[header] = req.env["HTTP_#{header.tr('-', '_').upcase}"]
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.port == 443

      http.open_timeout = @timeout
      http.read_timeout = @timeout

      sub_response = http.start do |http|
        http.request(sub_request)
      end

      headers = {}
      cookies = []

      sub_response.each_header do |k, v|
        if k.to_s =~ /set-cookie/i
          cookies << v
        else
          headers[k] = v unless k.to_s =~ /content-length|transfer-encoding|set-cookie/i
        end
      end

      (0..cookies.length - 1).each do |idx|
        k, v = extract_cookie(cookies[idx])

        cookies[idx] = "#{k}=#{v}; path=/"
        cookies[idx] << "; domain=#{@domain}" if @domain
        cookies[idx] << '; secure' if @secure
      end

      headers['Set-Cookie'] = cookies.join('\n')

      [sub_response.code.to_i, headers, [sub_response.read_body]]
    end

    private

    # Removes path and expiration values from cookie.
    # Restricts cookie to values specified in @proxied_cookies.
    def extract_cookie(cookie_val)
      cleaned_val = cookie_val.gsub(/(path=[^,;]+[,;])|(expires=.*)/, ' ')
      cleaned_val.gsub!(/\s+/, ' ')

      if @proxied_cookies.empty?
        return ['', cleaned_val]
      else
        @proxied_cookies.each do |key|
          if match = cleaned_val.match(/#{key}=(?<val>(.*));/i)
            return [key, match[:val]]
          end
        end
      end

      ['', '']
    end
  end
end
