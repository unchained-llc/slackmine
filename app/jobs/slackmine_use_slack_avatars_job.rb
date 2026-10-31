# frozen_string_literal: true

class SlackmineUseSlackAvatarsJob < ApplicationJob
  queue_as :slack

  def perform(user_id, key)
    user = User.find_by(id: user_id)
    if user
      Slackmine::UseSlackAvatars.refresh(user, key)
    else
      Rails.cache.delete("#{key}/pending")
    end
  end
end
