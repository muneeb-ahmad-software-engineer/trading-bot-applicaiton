# Base class for API serializers.
#
# API response shapes live here rather than in controllers, for two reasons:
#
#   1. The same resource is returned from several endpoints. Before this, a
#      position was serialised in three controllers and they could drift apart.
#   2. The MT5 Expert Advisor parses these payloads by key. A shape defined in
#      one place can be changed deliberately; a shape copy-pasted into three
#      controllers gets changed by accident.
#
# Decimals are emitted as fixed-scale strings — see #money, #lots and #price.
class ApplicationSerializer
  MONEY_SCALE = 2
  LOT_SCALE   = 2
  PRICE_SCALE = 5

  attr_reader :object

  def initialize(object)
    @object = object
  end

  # Serialize a collection with the same serializer.
  def self.collection(objects)
    objects.map { |object| new(object).as_json }
  end

  def as_json(*)
    raise NotImplementedError, "#{self.class} must implement #as_json"
  end

  private

  def money(value) = decimal(value, MONEY_SCALE)
  def lots(value)  = decimal(value, LOT_SCALE)
  def price(value) = decimal(value, PRICE_SCALE)
  def percent(value) = decimal(value, MONEY_SCALE)

  # Fixed scale, as a string. BigDecimal#to_s drops trailing zeros, which would
  # give a client "0.5" for one request and "0.50" for the next, and invites
  # float parsing of money on the other side.
  def decimal(value, scale)
    return nil if value.nil?

    format("%.#{scale}f", value)
  end

  def timestamp(value) = value&.utc&.iso8601
end
