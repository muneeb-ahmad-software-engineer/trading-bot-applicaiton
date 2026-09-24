# Serves the offline fallback shell that the service worker falls back to when
# a navigation request cannot reach the network.
class PwaController < ApplicationController
  allow_unauthenticated_access
  layout "offline"

  def offline
  end
end
