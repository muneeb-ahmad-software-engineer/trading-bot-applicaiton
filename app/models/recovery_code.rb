# A single-use backup code for when a user loses their authenticator device.
#
# Stored as a digest only, like every other credential in this application, and
# consumed atomically so the same code cannot be spent twice by two concurrent
# requests.
class RecoveryCode < ApplicationRecord
  BATCH_SIZE = 10
  # Base32-ish alphabet with no 0/O/1/I, because these get read off a screen and
  # typed by hand, often transcribed from a printout.
  ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".chars.freeze
  GROUPS = 2
  GROUP_LENGTH = 5

  belongs_to :user

  scope :unused, -> { where(used_at: nil) }

  class << self
    # Replaces any existing codes. Returns the plaintext codes, which are shown
    # to the user exactly once and are not recoverable afterwards.
    def regenerate_for(user)
      codes = Array.new(BATCH_SIZE) { generate_code }

      transaction do
        where(user:).delete_all
        codes.each { |code| create!(user:, code_digest: digest(code)) }
      end

      codes
    end

    # Consumes a code if it matches an unused one. Returns true on success.
    def consume(user:, code:)
      normalized = normalize(code)
      return false if normalized.blank?

      # Marking by conditional UPDATE means two simultaneous requests presenting
      # the same code cannot both succeed — the second updates zero rows.
      updated = unused.where(user:, code_digest: digest(normalized))
                      .update_all(used_at: Time.current)

      updated.positive?
    end

    def digest(code) = OpenSSL::Digest::SHA256.hexdigest(normalize(code))

    # Accepts the code however the user typed it: spaces, dashes, lower case.
    def normalize(code) = code.to_s.strip.upcase.gsub(/[^A-Z0-9]/, "")

    private

    def generate_code
      Array.new(GROUPS) { Array.new(GROUP_LENGTH) { ALPHABET.sample(random: SecureRandom) }.join }.join("-")
    end
  end

  def used? = used_at.present?
end
