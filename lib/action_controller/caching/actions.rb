require "set"

module ActionController
  module Caching
    # Action caching is similar to page caching by the fact that the entire
    # output of the response is cached, but unlike page caching, every
    # request still goes through Action Pack. The key benefit of this is
    # that filters run before the cache is served, which allows for
    # authentication and other restrictions on whether someone is allowed
    # to execute such action.
    #
    #   class ListsController < ApplicationController
    #     before_action :authenticate, except: :public
    #
    #     caches_page   :public
    #     caches_action :index, :show
    #   end
    #
    # In this example, the +public+ action doesn't require authentication
    # so it's possible to use the faster page caching. On the other hand
    # +index+ and +show+ require authentication. They can still be cached,
    # but we need action caching for them.
    #
    # Action caching uses fragment caching internally and an around
    # filter to do the job. The fragment cache is named according to
    # the host and path of the request. A page that is accessed at
    # <tt>http://david.example.com/lists/show/1</tt> will result in a fragment named
    # <tt>david.example.com/lists/show/1</tt>. This allows the cacher to
    # differentiate between <tt>david.example.com/lists/</tt> and
    # <tt>jamis.example.com/lists/</tt> -- which is a helpful way of assisting
    # the subdomain-as-account-key pattern.
    #
    # Different representations of the same resource, e.g.
    # <tt>http://david.example.com/lists</tt> and
    # <tt>http://david.example.com/lists.xml</tt>
    # are treated like separate requests and so are cached separately.
    # Keep in mind when expiring an action cache that
    # <tt>action: "lists"</tt> is not the same as
    # <tt>action: "lists", format: :xml</tt>.
    #
    # You can modify the default action cache path by passing a
    # <tt>:cache_path</tt> option. This will be passed directly to
    # <tt>ActionCachePath.new</tt>. This is handy for actions with
    # multiple possible routes that should be cached differently. If a
    # block is given, it is called with the current controller instance.
    # If an object that responds to <tt>call</tt> is given, it'll be called
    # with the current controller instance.
    #
    # And you can also use <tt>:if</tt> (or <tt>:unless</tt>) to pass a
    # proc that specifies when the action should be cached.
    #
    # As of Rails 3.0, you can also pass <tt>:expires_in</tt> with a time
    # interval (in seconds) to schedule expiration of the cached item.
    #
    # The following example depicts some of the points made above:
    #
    #   class CachePathCreator
    #     def initialize(name)
    #       @name = name
    #     end
    #
    #     def call(controller)
    #       "cache-path-#{@name}"
    #     end
    #   end
    #
    #
    #   class ListsController < ApplicationController
    #     before_action :authenticate, except: :public
    #
    #     caches_page :public
    #
    #     caches_action :index, if: Proc.new do
    #       !request.format.json?  # cache if is not a JSON request
    #     end
    #
    #     caches_action :show, cache_path: { project: 1 },
    #       expires_in: 1.hour
    #
    #     caches_action :feed, cache_path: Proc.new do
    #       if params[:user_id]
    #         user_list_url(params[:user_id, params[:id])
    #       else
    #         list_url(params[:id])
    #       end
    #     end
    #
    #     caches_action :posts, cache_path: CachePathCreator.new("posts")
    #   end
    #
    # If you pass <tt>layout: false</tt>, it will only cache your action
    # content. That's useful when your layout has dynamic information.
    #
    # Warning: If the format of the request is determined by the Accept HTTP
    # header the Content-Type of the cached response could be wrong because
    # no information about the MIME type is stored in the cache key. So, if
    # you first ask for MIME type M in the Accept header, a cache entry is
    # created, and then perform a second request to the same resource asking
    # for a different MIME type, you'd get the content cached for M.
    #
    # The <tt>:format</tt> parameter is taken into account though. The safest
    # way to cache by MIME type is to pass the format in the route.
    module Actions
      extend ActiveSupport::Concern

      module ClassMethods
        # Declares that +actions+ should be cached.
        # See ActionController::Caching::Actions for details.
        def caches_action(*actions)
          return unless perform_caching && Rails.application.config.action_controller.cache_store
          options = actions.extract_options!
          filter_options = options.extract!(:if, :unless).merge(only: actions)
          cache_options  = options.extract!(:cache_path).merge(store_options: options)

          around_action ActionCacheFilter.new(cache_options), filter_options
        end
      end

      def caching_allowed?
        (request.get? || request.head?) && response.status == 200
      end

    protected

      class ActionCacheFilter # :nodoc:
        def initialize(options, &block)
          @cache_path, @store_options =
            options.values_at(:cache_path, :store_options)
        end

        def around(controller)
          path_options = expand_option(controller, @cache_path)
          cache_path = ActionCachePath.new(controller, path_options || {})
          body = Rails.cache.read(cache_path.path, @store_options)

          unless body
            body = yield
            Rails.cache.write(cache_path.path, body, @store_options)
          end

          body = render_to_string(controller, body)

          controller.response_body = body
          controller.content_type = Mime[cache_path.extension]
        end

        if ActionPack::VERSION::STRING < "4.1"
          def render_to_string(controller, body)
            controller.render_to_string(text: body)
          end
        else
          def render_to_string(controller, body)
            controller.render_to_string(html: body.html_safe)
          end
        end

        private
          def expand_option(controller, option)
            option = option.to_proc if option.respond_to?(:to_proc)

            if option.is_a?(Proc)
              case option.arity
              when -2, -1, 1
                controller.instance_exec(controller, &option)
              when 0
                controller.instance_exec(&option)
              else
                raise ArgumentError, "Invalid proc arity of #{option.arity} - proc options should have an arity of 0 or 1"
              end
            elsif option.respond_to?(:call)
              option.call(controller)
            else
              option
            end
          end
      end

      class ActionCachePath
        attr_reader :path, :extension

        # If +infer_extension+ is +true+, the cache path extension is looked up from the request's
        # path and format. This is desirable when reading and writing the cache, but not when
        # expiring the cache - +expire_action+ should expire the same files regardless of the
        # request format.
        def initialize(controller, options = {}, infer_extension = true)
          if infer_extension
            if controller.params.key?(:format)
              @extension = controller.params[:format]
            elsif !controller.request.format.html?
              @extension = controller.request.format.to_sym
            else
              @extension = nil
            end

            options.reverse_merge!(format: @extension) if options.is_a?(Hash)
          end

          path = controller.url_for(options).split("://", 2).last
          @path = normalize!(path)
        end

      private
        def normalize!(path)
          ext = URI.parser.escape(extension.to_s) if extension
          path << "index" if path[-1] == ?/
          path << ".#{ext}" if extension && !path.split("?", 2).first.ends_with?(".#{ext}")
          URI.parser.unescape(path)
        end
      end
    end
  end
end
