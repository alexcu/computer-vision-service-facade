require 'securerandom'

class Key
  @id = SecureRandom.uuid

  def initialize()
  end

  def id
    @id
  end

  def results
  end
end
