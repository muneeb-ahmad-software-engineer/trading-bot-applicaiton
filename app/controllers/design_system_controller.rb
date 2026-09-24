# Living style guide for the global design system.
#
# Routed only outside production (see config/routes.rb): it is a development
# tool, not a public page, and it should never be reachable or indexed on a
# deployed site.
class DesignSystemController < ApplicationController
  allow_unauthenticated_access

  def show
  end
end
