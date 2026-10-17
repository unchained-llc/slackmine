# frozen_string_literal: true
require 'json'

namespace :slackmine do
  desc 'Sign trusted unsigned legacy quotes (dry run; apply=true backup=/absolute/file.jsonl to write)'
  task sign_legacy_quotes: :environment do
    abort 'apply must be true or false' unless [nil, 'true', 'false'].include?(ENV['apply'])
    apply = ENV['apply'] == 'true'
    backup = nil
    if apply
      path = ENV['backup'].to_s
      abort 'backup must be an absolute, new file path' unless path.start_with?('/')
      backup = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
    end
    totals = Hash.new(0)
    begin
      [[Issue, :description], [Journal, :notes]].each do |model, field|
        model.where("#{field} LIKE ?", '%[slack-quote:%').find_each do |record|
          process = lambda do
            original = record.public_send(field)
            updated, counts = Slackmine::LinkQuotes.sign_legacy(original)
            counts.each { |key, value| totals[key] += value }
            next if original == updated

            if apply
              backup.puts(JSON.generate(model: model.name, id: record.id, field: field, original: original, updated: updated))
              backup.flush
              backup.fsync
              # No callbacks, notifications, journals or timestamp changes.
              record.update_columns(field => updated)
            end
            totals[:records] += 1
          end
          apply ? record.with_lock { process.call } : process.call
        end
      end
      puts JSON.generate(totals.merge(apply: apply, backup: apply ? ENV['backup'] : nil))
    ensure
      backup&.close
    end
  end
end
