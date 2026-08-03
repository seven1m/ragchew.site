module Tables
  class Message < ActiveRecord::Base
    belongs_to :net
    has_many :message_reactions, dependent: :delete_all

    scope :visible_to, ->(user) {
      where(blocked: false).or(where('UPPER(call_sign) = ?', user.call_sign.upcase))
    }

    def as_json(options = {})
      if options[:include_reactions]
        super.merge(
          reactions: message_reactions
        )
      else
        super
      end
    end
  end
end
