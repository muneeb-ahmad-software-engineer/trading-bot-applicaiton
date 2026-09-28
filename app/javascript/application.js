// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"
import "pwa"

// iOS Safari ignores user-scalable=no in the viewport meta, so block pinch-zoom
// gestures directly. Double-tap zoom is handled by touch-action in base.css.
document.addEventListener("gesturestart", (event) => event.preventDefault())
