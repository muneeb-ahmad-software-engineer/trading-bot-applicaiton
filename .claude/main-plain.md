You are working on a new Ruby on Rails application.

I want you to turn this Rails application into the foundation of a production-quality SaaS platform for an automated Gold (XAUUSD) grid trading system.

## 1. Understand the product first

The application will eventually allow users to:

1. Create an account and securely log in.
2. Configure an automated XAUUSD/Gold grid trading strategy.
3. Configure all important trading parameters from the frontend.
4. Start and stop their trading strategy.
5. Monitor their trading bot, positions, orders, profit/loss, and account status.
6. Communicate with an MT5 Expert Advisor through APIs.
7. Later use the exact same backend APIs from native mobile applications.

The Rails application will be the main control/management platform.

MT5 will eventually act as the trading execution layer through an Expert Advisor (EA).

Important architectural principle:

Rails = user accounts, strategy configuration, business logic, API, dashboard, settings, authentication and application state.

MT5 EA = actual broker-side trading execution, order placement, position management and MT5-specific operations.

Do NOT implement actual trading execution yet. We are currently building the application foundation and UI.

---

# 2. Architecture

Build the application as a Rails monolith with:

* Rails full-stack web application
* Progressive Web App (PWA)
* REST API from day one
* PostgreSQL
* Clean service-oriented architecture
* Authentication-ready architecture
* Future MT5 integration
* Future iOS/Android application compatibility

The API must be treated as a first-class part of the application.

Use API versioning from the beginning:

/api/v1/

Do not create a separate frontend application at this stage.

---

# 3. Progressive Web App

Make the Rails application a proper PWA.

Implement:

* Web App Manifest
* Service worker
* Installable application
* Mobile-friendly responsive UI
* App icons/placeholders
* Theme color
* Standalone display mode
* Appropriate viewport/meta configuration
* Offline-friendly shell where appropriate
* Proper PWA structure

Do not claim that the application is fully offline-capable if the trading functionality requires an internet connection.

Trading functionality must clearly require an online connection.

The PWA should feel like a professional mobile application when installed.

---

# 4. Tailwind CSS

Use Tailwind CSS for the entire UI.

First inspect the existing Rails project and determine whether Tailwind is already installed.

If it is not installed, use the current recommended Rails/Tailwind integration rather than manually introducing an unnecessary frontend framework.

Use the current Tailwind CSS architecture appropriate for the installed version.

Do NOT introduce React, Vue, Next.js or another frontend framework.

Use Rails views + Hotwire/Turbo/Stimulus where appropriate.

---

# 5. Global Design System

Before creating the landing page, create a centralized global design system.

The goal is that every future page uses the same visual language.

Create a dedicated global styling/design-token structure containing:

### Colors

Define semantic colors such as:

* background
* surface
* surface-elevated
* border
* primary
* primary-hover
* secondary
* success
* warning
* danger
* info
* text-primary
* text-secondary
* text-muted

The exact colors should feel appropriate for a professional financial/trading SaaS.

Avoid excessive neon colors or a casino-like appearance.

### Typography

Define consistent:

* font family
* heading styles
* body text
* labels
* captions
* numbers
* financial figures

### Spacing

Use a consistent spacing system.

### Border radius

Define consistent:

* small radius
* medium radius
* large radius
* card radius
* button radius

### Shadows

Create a small consistent shadow system.

### Components

Create reusable styling/classes/components for:

* Buttons
* Cards
* Inputs
* Selects
* Checkboxes
* Radio buttons
* Badges
* Alerts
* Navigation
* Tables
* Modals
* Form sections
* Status indicators

Do not scatter arbitrary colors and styling throughout templates.

If a color, spacing, radius or visual pattern is reused, it should come from the global design system.

---

# 6. Design Direction

The product is a serious financial/trading SaaS platform.

The visual design should feel:

* Professional
* Modern
* Trustworthy
* Technical
* Clean
* Premium
* Data-oriented
* Responsive

Avoid:

* Generic bootstrap-looking UI
* Excessive gradients
* Overly flashy trading/casino aesthetics
* Huge unnecessary animations
* Excessive rounded cards
* Clutter
* Fake trading performance claims
* Fake profit numbers

The application should look like a legitimate trading infrastructure product rather than a gambling website.

Use subtle visual hierarchy and restrained animations.

---

# 7. Landing Page

After establishing the global design system, build the public landing page.

The landing page should introduce the product without making profitability claims.

Suggested structure:

## Navigation

Logo/product name

Navigation:

* How It Works
* Features
* Risk Management
* FAQ

Actions:

* Log In
* Get Started

Make the navigation responsive.

---

## Hero Section

Clearly communicate:

Automated Gold Grid Trading

Example messaging:

"Configure. Connect. Automate Your XAUUSD Strategy."

Explain that users can configure their Gold grid strategy and manage it from one platform.

Primary CTA:

"Get Started"

Secondary CTA:

"How It Works"

Do NOT claim guaranteed profits or guaranteed returns.

---

## How It Works

Show a simple 3-step flow:

1. Create your account
2. Configure your XAUUSD strategy
3. Connect and run through MT5

Make the flow visually clear.

---

## Strategy Configuration

Explain that users can configure:

* Order direction
* Grid spacing
* Initial lot size
* Lot sizing mode
* Grid levels
* Basket Take Profit
* Basket Stop Loss
* Maximum positions
* Maximum exposure
* Drawdown protection
* Margin protection

Do not imply that any particular configuration is profitable.

---

## Dashboard Preview

Create a visual mockup/preview of the future dashboard.

Show realistic UI examples such as:

* Bot status
* XAUUSD
* Current price
* Grid status
* Open positions
* Basket P/L
* Take Profit
* Stop Loss

These should be clearly presented as interface examples, not real trading results.

---

## Risk Management

This should be an important section.

Explain that users can configure controls such as:

* Maximum positions
* Maximum exposure
* Basket stop loss
* Drawdown protection
* Margin protection
* Maximum spread
* Emergency stop

Do not use language suggesting these controls eliminate trading risk.

---

## MT5 Integration

Explain the architecture simply:

Your platform manages the strategy and configuration.

MT5/Expert Advisor handles execution with the connected broker.

Do not implement the actual MT5 connection yet.

Create the UI/architecture so it can be integrated later.

---

## Security / Reliability

Create a section explaining the platform is designed around:

* Secure authentication
* API-first architecture
* User-specific configuration
* Protected API endpoints
* Separation between strategy management and execution

Do not make security claims that have not actually been implemented.

---

## FAQ

Include useful questions such as:

* What is an XAUUSD grid strategy?
* What is MT5?
* Does the platform execute trades directly?
* Can I change my strategy settings?
* Can I use the platform from mobile?
* Is trading risk-free?

The answer to the last question must clearly be no.

---

# 8. Authentication Foundation

Even though the immediate task is the landing page, prepare the application architecture for full authentication.

Eventually users should have:

* Sign up
* Login
* Logout
* Email verification
* Forgot password
* Reset password
* Profile
* Account settings

Do not build unnecessary authentication complexity if it is not needed yet, but structure the application so authentication can be added cleanly.

---

# 9. Future Dashboard Architecture

Create the visual/route foundation for a future authenticated dashboard.

Suggested routes:

/

/login

/signup

/dashboard

/strategies

/strategies/new

/strategies/:id

/settings

/profile

The dashboard will eventually contain:

* Account overview
* Bot status
* Active strategy
* XAUUSD price
* Open positions
* Pending orders
* Basket P/L
* Trading history
* Risk metrics
* Strategy configuration

For now, do not implement actual trading data.

Use clearly labelled placeholder/mock data only where necessary for UI development.

---

# 10. API Architecture

Prepare the application for future mobile applications.

Use:

/api/v1/

Future endpoints will include concepts such as:

POST /api/v1/auth/login
POST /api/v1/auth/signup

GET /api/v1/profile

GET /api/v1/strategies
POST /api/v1/strategies
GET /api/v1/strategies/:id
PATCH /api/v1/strategies/:id

POST /api/v1/strategies/:id/start
POST /api/v1/strategies/:id/stop

GET /api/v1/trading/account
GET /api/v1/trading/orders
GET /api/v1/trading/positions
GET /api/v1/trading/history

Do not implement every endpoint yet.

Establish clean API namespacing and structure so future development does not require a major rewrite.

---

# 11. Code Quality

Follow Rails conventions.

Prefer:

* RESTful routes
* Thin controllers
* Service objects for business logic
* Form objects where useful
* Strong parameters
* Model validations
* Policy/authorization layer when needed
* API serializers/presenters where appropriate
* Clear namespaces
* Reusable Rails partials/components

Do not create unnecessary abstractions.

Keep the project understandable for another Rails developer.

---

# 12. Important

Before changing anything:

1. Inspect the existing Rails project.
2. Determine Rails version.
3. Determine whether Tailwind is already installed.
4. Determine the current asset pipeline/setup.
5. Determine whether Hotwire/Turbo/Stimulus are available.
6. Reuse the existing setup where appropriate.
7. Do not unnecessarily replace working dependencies.
8. Do not introduce React/Vue/Next.js.

Then implement the foundation.

---

# 13. Deliverables for this task

Complete the following:

1. Configure/verify Tailwind CSS.
2. Create the global design system.
3. Configure the PWA foundation.
4. Create the public landing page.
5. Make the landing page fully responsive.
6. Create reusable UI components/partials.
7. Prepare the route structure.
8. Prepare the API namespace structure.
9. Add appropriate SEO metadata for the landing page.
10. Ensure accessibility basics.
11. Ensure the application works properly on desktop, tablet and mobile.
12. Run the Rails test/build/lint checks available in the project.
13. Fix any errors you introduce.

Do not build the actual trading engine yet.

Do not connect to a broker yet.

Do not implement MT5 execution yet.

Do not invent trading performance statistics.

At the end, give me:

* What you changed
* Files created/modified
* Dependencies added
* How the PWA works
* How the design system is organized
* How the future MT5 integration will fit into the architecture
* Any decisions or assumptions you made
* Any commands I need to run
* Any remaining issues
