module NetLike
  def local_net?
    host == 'ragchew.site'
  end

  def show_circle?
    center_latitude && center_longitude && center_radius
  end

  # accepts an array of hashes, like this:
  #
  #     [
  #       { name: 'YL*' },
  #       { name: 'YL System 15m Session', frequency: '21.373' },
  #       ...
  #     ]
  #
  # ...and turns it into SQL like this:
  #
  #     SELECT `nets`.* FROM `nets` WHERE (
  #       `nets`.`name` LIKE 'YL%' OR
  #       `nets`.`name` LIKE 'YL System 15m Session' AND `nets`.`frequency` = '21.373' OR
  #       ...
  #     )
  #
  def self.included(klass)
    klass.class_eval do
      scope :matching_conditions, ->(conditions) {
        t = arel_table
        scope = nil
        conditions.each do |condition|
          s = where(t[:name].matches(condition[:name].gsub('%', "\\%").tr('*', '%')))
          s.where!(frequency: condition[:frequency]) if condition[:frequency]
          if scope
            scope = scope.or(s)
          else
            scope = s
          end
        end
        scope
      }
    end
  end
end
