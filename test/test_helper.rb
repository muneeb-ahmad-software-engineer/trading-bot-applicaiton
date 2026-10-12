ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# CI has no master key, so credentials are empty there. The push tests read web_push from
# credentials; give them a fixed test-only VAPID pair when none is present. Tests that need
# "no keys" stub it to nil themselves. This pair signs nothing real.
TEST_WEB_PUSH = {
  public_key: "BCbIPAfi54xTL7Y8WNkegR_72aNymlekHDbgIvP7UqinZmTgwqAdb8KjUF_lrkRxAOvfW8vhHEXFM4R92ygaerY",
  private_key: "hJqtJ1W10AID-tqnPNL5m-f7oMS3glBEw3dZQzjRDEU"
}.freeze
Rails.application.credentials.define_singleton_method(:web_push) { TEST_WEB_PUSH } unless Rails.application.credentials.web_push

# Shared test support (test/support/*.rb). Required rather than autoloaded:
# these are test helpers, not application code, and must never be reachable
# from app/.
Dir[Rails.root.join("test/support/**/*.rb")].each { |file| require file }

module ActiveSupport
  class TestCase
    # Process-based parallelism is off by default.
    #
    # On a cold start — when the per-worker test databases do not yet exist —
    # workers race to run CREATE DATABASE ... TEMPLATE against the same template
    # database. PostgreSQL refuses to copy a template that another connection is
    # using, and the run hangs indefinitely rather than failing with an error.
    # Reproduced repeatedly here with 4 and 12 workers; 2 usually survives.
    #
    # The whole suite runs in about six seconds in one process, so parallelism
    # buys very little and costs a hang that looks like a broken test suite.
    # Opt in with PARALLEL_WORKERS=N once the databases exist.
    parallelize(workers: Integer(ENV.fetch("PARALLEL_WORKERS", 1)))

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include Mt5Helpers

    # Add more helper methods to be used by all tests here...

    # Temporarily replaces a singleton method, restoring whatever was there
    # before — including nothing, for methods that only answer through
    # method_missing.
    #
    # Minitest 6 dropped minitest/mock, and this project deliberately carries no
    # mocking gem. Some behaviour cannot be reached without standing in for a
    # third party, though: push delivery is defined by how it handles a push
    # service that is slow, gone, or refusing the endpoint, and none of those
    # can be provoked by talking to the real thing. Kept deliberately small, and
    # for external seams only — never to stub this application's own objects.
    def stubbing(receiver, method_name, replacement)
      singleton = receiver.singleton_class
      original = singleton.instance_method(method_name) if singleton.method_defined?(method_name)

      # Invoked through #call rather than handed to define_method directly:
      # define_method would rebind self to the receiver, so a replacement that
      # called back into the test would raise NoMethodError — and a stubbed
      # method that swallows errors would quietly turn that into a passing test.
      singleton.define_method(method_name) { |*args, **options, &block| replacement.call(*args, **options, &block) }
      yield
    ensure
      singleton.remove_method(method_name)
      singleton.define_method(method_name, original) if original
    end
  end
end
