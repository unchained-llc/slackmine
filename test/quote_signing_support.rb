# frozen_string_literal: true
# A deterministic substitute for the Rails application's key generator.
class QuoteTestKeyGenerator
  def generate_key(_purpose, _length)
    'slackmine-test-only-quote-signing-key'
  end
end
