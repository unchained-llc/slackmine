# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/slackmine/thread_state'

class ThreadStateTest < Minitest::Test
  STATE = Slackmine::ThreadState

  def setup
    skip 'Set SLACKMINE_TEST_REDIS_URL to a dedicated test Redis' unless ENV['SLACKMINE_TEST_REDIS_URL']
    require 'sidekiq'
    Sidekiq.configure_client { |config| config.redis = { url: ENV['SLACKMINE_TEST_REDIS_URL'] } }
    @team = 'T' + SecureRandom.hex(8).upcase
    @source = { 'channel' => 'C123', 'ts' => '1791001000.000001', 'issue_id' => 7,
                'cutoff' => '1791001000.000010', 'nonce' => SecureRandom.hex(16) }
    @keys = []
  end

  def teardown
    if @team
      STATE.with_redis { |redis| redis.call('DEL', *@keys) } unless @keys.empty?
    end
  end

  def test_connection_is_atomic_and_closed_nonce_cannot_be_reactivated
    competing = @source.merge('nonce' => SecureRandom.hex(16))
    @keys += [STATE.connection_key('ATEST', @team, @source), STATE.closed_key('ATEST', @team, @source), STATE.closed_key('ATEST', @team, competing)]
    gate = Queue.new
    threads = [@source, competing].map do |source|
      Thread.new { gate.pop; [source, STATE.connect('ATEST', @team, source)] }
    end
    2.times { gate << true }
    results = threads.map(&:value)
    assert_equal %w[conflict connected], results.map(&:last).sort
    winner = results.find { |_, result| result == 'connected' }.first
    loser = results.find { |_, result| result == 'conflict' }.first
    assert_equal winner['nonce'], STATE.connection('ATEST', @team, winner)['nonce']
    refute STATE.disconnect('ATEST', @team, loser)
    assert STATE.disconnect('ATEST', @team, winner)
    assert_equal 'closed', STATE.connect('ATEST', @team, winner)
    assert_equal 'connected', STATE.connect('ATEST', @team, loser)
    assert_equal(-1, STATE.with_redis { |redis| redis.call('TTL', STATE.connection_key('ATEST', @team, loser)) })
  end

  def test_individual_message_claims_cover_partial_batches_and_pending_outcomes
    events = %w[1791001000.000001 1791001000.000002].map { |ts| { 'channel' => 'C123', 'ts' => ts } }
    @keys += events.map { |event| STATE.import_key(7, @team, event) }
    token, indices = STATE.claim(7, @team, events.first(1))
    assert_equal [0], indices
    assert_raises(STATE::PendingImport) { STATE.claim(7, @team, events) }
    STATE.finish(7, @team, events.first(1), token)
    token, indices = STATE.claim(7, @team, events)
    assert_equal [1], indices
    STATE.release(7, @team, events.last(1), token)
    token, indices = STATE.claim(7, @team, events)
    assert_equal [1], indices
    STATE.finish(7, @team, events.last(1), token)
    assert_empty STATE.claim(7, @team, events).last
    assert_equal(-1, STATE.with_redis { |redis| redis.call('TTL', @keys.first) })
    assert_equal STATE.import_key(7, @team, events.first.merge('ts' => '1791001000.1')),
                 STATE.import_key(7, @team, events.first.merge('ts' => '1791001000.100000'))
    refute_equal STATE.import_key(7, @team, events.first), STATE.import_key(8, @team, events.first)
    refute_equal STATE.import_key(7, @team, events.first), STATE.import_key(7, @team, events.first.merge('channel' => 'C999'))
  end

  def test_pending_journal_is_recovered_after_commit_and_cleared_after_rollback
    events = [{ 'channel' => 'C123', 'ts' => '1791001000.000001' }]
    @keys << STATE.import_key(7, @team, events.first)
    journals = Object.new
    journals.define_singleton_method(:find_by) { |id:| id == 42 ? Object.new : nil }
    issue = Struct.new(:id, :journals).new(7, journals)
    token, = STATE.claim(7, @team, events)
    recorded = STATE.record_journal(7, @team, events, token, 42)
    assert_includes recorded, ':journal:42'
    STATE.stub(:journal_contains_event?, true) { STATE.recover(issue, @team, events) }
    assert_empty STATE.claim(7, @team, events).last
    STATE.with_redis { |redis| redis.call('DEL', @keys.first) }
    token, = STATE.claim(7, @team, events)
    STATE.record_journal(7, @team, events, token, 43)
    STATE.recover(issue, @team, events)
    assert_equal [0], STATE.claim(7, @team, events).last
  end

  def test_ambiguous_journal_is_not_assumed_to_be_the_import
    event = { 'channel' => 'C123', 'ts' => '1791001000.000001' }
    @keys << STATE.import_key(7, @team, event)
    journals = Object.new
    journals.define_singleton_method(:find_by) { |id:| Object.new }
    issue = Struct.new(:id, :journals).new(7, journals)
    token, = STATE.claim(7, @team, [event])
    STATE.record_journal(7, @team, [event], token, 42)
    STATE.stub(:journal_contains_event?, false) do
      assert_raises(STATE::PendingImport) { STATE.recover(issue, @team, [event]) }
    end
    assert_raises(STATE::PendingImport) { STATE.claim(7, @team, [event]) }
  end

  def test_two_simultaneous_claims_cannot_both_acquire_the_same_message
    event = { 'channel' => 'C123', 'ts' => '1791001000.000001' }
    @keys << STATE.import_key(7, @team, event)
    gate = Queue.new
    attempts = 2.times.map do
      Thread.new do
        gate.pop
        begin
          STATE.claim(7, @team, [event]).last.empty? ? :duplicate : :claimed
        rescue STATE::PendingImport
          :pending
        end
      end
    end
    2.times { gate << true }
    assert_equal [:claimed, :pending], attempts.map(&:value).sort
  end
end
