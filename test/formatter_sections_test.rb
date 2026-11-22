# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/slackmine/formatter'

class FormatterSectionsTest < Minitest::Test
  def sections(source, heading: nil, limit: 2800)
    Slackmine::Formatter.mrkdwn_sections(heading, source, limit: limit).map do |block|
      value = block.fetch('text').fetch('text')
      assert_operator value.length, :<=, limit
      assert_equal 0, value.scan('```').length % 2, value
      value
    end
  end

  def test_long_console_output_keeps_every_line_inside_balanced_code_blocks
    lines = 100.times.map { |index| "php-intl-8.2.36-#{index}.module+el8.10.0.x86_64\n" }
    source = "バージョン確認\n```console\n#{lines.join}```\nアップデートなしを確認\n```console\nComplete!\n```"
    blocks = sections(source, heading: '追加コメント')

    assert_operator blocks.length, :>, 1
    code = blocks.flat_map { |block| block.scan(/```\n(.*?)\n```/m).flatten }
    assert_equal lines.join + "Complete!\n", code.join
    lines.each { |line| assert code.any? { |part| part.include?(line) }, line }
    assert_includes blocks.join.gsub(/```\n.*?\n```/m, ''), 'アップデートなしを確認'
    refute_includes blocks.join, '```console'
  end

  def test_code_fence_at_section_boundary_is_not_split
    source = "#{'あ' * 2798}\n```ruby\nputs :ok\n```\n末尾"
    blocks = sections(source)
    assert_equal "#{'あ' * 2798}\n", blocks.first
    assert_includes blocks.last, "```\nputs :ok\n\n```"
    assert blocks.last.end_with?("\n末尾")
  end

  def test_oversized_single_code_line_preserves_characters_and_escaping
    body = '<&日本語>' * 1000
    code = sections("```c++\n#{body}\n```").flat_map do |block|
      block.scan(/```\n(.*?)\n```/m).flatten
    end
    assert_equal Slackmine::Formatter.text(body + "\n"), code.join
    code.each { |part| refute_match(/&(?:amp|lt|gt)?\z/, part) }
  end

  def test_plain_text_prefers_newlines_and_preserves_all_text
    source = "#{'a' * 2000}\n#{'b' * 2000}\n末尾"
    blocks = sections(source)
    assert_equal "#{'a' * 2000}\n", blocks.first
    assert_equal source, blocks.join
  end

  def test_tilde_fences_and_empty_code_blocks
    assert_equal ["```\nhello\n\n```\n```\n\n```"], sections("~~~text\nhello\n~~~\n```\n```")
  end

  def test_escaped_text_and_heading_fit_in_section_limit
    source = '<&>' * 1000
    blocks = sections(source, heading: '追加コメント')
    assert_equal "*追加コメント*\n#{Slackmine::Formatter.text(source)}", blocks.join
    blocks.each { |part| refute_match(/&(?:amp|lt|gt)?\z/, part) }
    assert_empty sections('', heading: '追加コメント')
  end
end
