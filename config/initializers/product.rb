# Central product identity. Referenced by the layout, the PWA manifest and any
# view that needs to name the product, so renaming happens in exactly one place.
Rails.application.config.x.product = ActiveSupport::OrderedOptions.new.merge!(
  name: "GoldGrid",
  tagline: "Automated XAUUSD Grid Trading",
  description: "Configure, connect and manage an automated XAUUSD gold grid " \
               "trading strategy, executed through your own MT5 Expert Advisor.",
  # Anchor colors for the PWA shell. These are kept in sync with the design
  # system tokens defined in app/assets/tailwind/application.css.
  # Where a terminal reaches this platform. Written into every EA
  # configuration file, so it must be the externally reachable URL, not
  # whatever host Rails happens to be bound to.
  base_url: ENV.fetch("PRODUCT_BASE_URL", "http://localhost:3000"),
  theme_color: "#0F172A",
  background_color: "#0B1120"
)
