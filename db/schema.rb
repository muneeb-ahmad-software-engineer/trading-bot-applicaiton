# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_09_19_121000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "account_snapshots", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "strategy_id"
    t.string "currency", default: "USD", null: false
    t.decimal "balance", precision: 18, scale: 2, null: false
    t.decimal "equity", precision: 18, scale: 2, null: false
    t.decimal "margin", precision: 18, scale: 2
    t.decimal "free_margin", precision: 18, scale: 2
    t.decimal "margin_level_percent", precision: 10, scale: 2
    t.datetime "recorded_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["recorded_at"], name: "index_account_snapshots_on_recorded_at"
    t.index ["strategy_id"], name: "index_account_snapshots_on_strategy_id"
    t.index ["user_id", "recorded_at"], name: "index_account_snapshots_on_user_id_and_recorded_at"
    t.index ["user_id"], name: "index_account_snapshots_on_user_id"
  end

  create_table "account_states", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "strategy_id"
    t.string "currency", default: "USD", null: false
    t.decimal "balance", precision: 18, scale: 2, null: false
    t.decimal "equity", precision: 18, scale: 2, null: false
    t.decimal "margin", precision: 18, scale: 2
    t.decimal "free_margin", precision: 18, scale: 2
    t.decimal "margin_level_percent", precision: 10, scale: 2
    t.datetime "recorded_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["strategy_id"], name: "index_account_states_on_strategy_id"
    t.index ["user_id"], name: "index_account_states_on_user_id", unique: true
  end

  create_table "api_tokens", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.string "token_digest", null: false
    t.datetime "last_used_at"
    t.datetime "expires_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "broker_credentials", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "server", null: false
    t.string "login", null: false
    t.text "password", null: false
    t.boolean "demo", default: true, null: false
    t.datetime "last_verified_at"
    t.string "last_verification_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_broker_credentials_on_user_id", unique: true
  end

  create_table "events", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "action", null: false
    t.string "subject_type"
    t.bigint "subject_id"
    t.jsonb "metadata", default: {}, null: false
    t.string "source", default: "web", null: false
    t.string "ip_address"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action", "occurred_at"], name: "index_events_on_action_and_occurred_at"
    t.index ["metadata"], name: "index_events_on_metadata", using: :gin
    t.index ["occurred_at"], name: "index_events_on_occurred_at"
    t.index ["subject_type", "subject_id"], name: "index_events_on_subject"
    t.index ["user_id", "occurred_at"], name: "index_events_on_user_id_and_occurred_at"
    t.index ["user_id"], name: "index_events_on_user_id"
  end

  create_table "mt5_instance_events", force: :cascade do |t|
    t.bigint "mt5_instance_id", null: false
    t.bigint "user_id"
    t.string "action", null: false
    t.string "from_state"
    t.string "to_state"
    t.string "source", default: "system", null: false
    t.text "reason"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.index ["action"], name: "index_mt5_instance_events_on_action"
    t.index ["mt5_instance_id", "occurred_at"], name: "index_mt5_instance_events_on_mt5_instance_id_and_occurred_at"
    t.index ["mt5_instance_id"], name: "index_mt5_instance_events_on_mt5_instance_id"
    t.index ["user_id"], name: "index_mt5_instance_events_on_user_id"
  end

  create_table "mt5_instances", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "worker_node_id", null: false
    t.bigint "strategy_id"
    t.bigint "api_token_id"
    t.string "uuid", null: false
    t.string "desired_state", default: "stopped", null: false
    t.string "state", default: "provisioning", null: false
    t.integer "pid"
    t.datetime "process_started_at"
    t.string "process_token"
    t.string "instance_dir", null: false
    t.integer "display_number"
    t.bigint "magic_number", null: false
    t.datetime "last_heartbeat_at"
    t.datetime "last_health_check_at"
    t.datetime "provisioned_at"
    t.datetime "started_at"
    t.datetime "connected_at"
    t.datetime "stopped_at"
    t.datetime "failed_at"
    t.datetime "terminated_at"
    t.datetime "last_transition_at"
    t.integer "restart_count", default: 0, null: false
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "next_restart_at"
    t.string "last_error_code"
    t.text "last_error_message"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token_id"], name: "index_mt5_instances_on_api_token_id"
    t.index ["magic_number"], name: "index_mt5_instances_on_magic_number", unique: true
    t.index ["next_restart_at"], name: "index_mt5_instances_on_next_restart_at"
    t.index ["state"], name: "index_mt5_instances_on_state"
    t.index ["strategy_id"], name: "index_mt5_instances_on_strategy_id"
    t.index ["user_id"], name: "index_mt5_instances_on_user_id"
    t.index ["user_id"], name: "index_mt5_instances_one_live_per_user", unique: true, where: "((state)::text <> 'terminated'::text)"
    t.index ["uuid"], name: "index_mt5_instances_on_uuid", unique: true
    t.index ["worker_node_id", "display_number"], name: "index_mt5_instances_one_display_per_node", unique: true, where: "(((state)::text <> 'terminated'::text) AND (display_number IS NOT NULL))"
    t.index ["worker_node_id", "state"], name: "index_mt5_instances_on_worker_node_id_and_state"
    t.index ["worker_node_id"], name: "index_mt5_instances_on_worker_node_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "alert_type", null: false
    t.string "title", null: false
    t.text "body", null: false
    t.string "severity", default: "info", null: false
    t.string "dedup_key", null: false
    t.string "url"
    t.string "subject_type"
    t.bigint "subject_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "emailed_at"
    t.datetime "pushed_at"
    t.datetime "read_at"
    t.datetime "resolved_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_notifications_on_created_at"
    t.index ["subject_type", "subject_id"], name: "index_notifications_on_subject"
    t.index ["user_id", "created_at"], name: "index_notifications_on_user_id_and_created_at"
    t.index ["user_id", "dedup_key", "resolved_at"], name: "index_notifications_on_user_id_and_dedup_key_and_resolved_at"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "strategy_id", null: false
    t.string "ticket", null: false
    t.string "order_type", null: false
    t.integer "grid_level"
    t.decimal "volume", precision: 10, scale: 2, null: false
    t.decimal "price", precision: 15, scale: 5, null: false
    t.string "status", default: "pending", null: false
    t.datetime "placed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["strategy_id", "ticket"], name: "index_orders_on_strategy_id_and_ticket", unique: true
    t.index ["strategy_id"], name: "index_orders_on_strategy_id"
  end

  create_table "positions", force: :cascade do |t|
    t.bigint "strategy_id", null: false
    t.string "ticket", null: false
    t.string "direction", null: false
    t.integer "grid_level"
    t.decimal "volume", precision: 10, scale: 2, null: false
    t.decimal "open_price", precision: 15, scale: 5, null: false
    t.decimal "current_price", precision: 15, scale: 5
    t.decimal "profit", precision: 18, scale: 2
    t.decimal "swap", precision: 18, scale: 2
    t.decimal "commission", precision: 18, scale: 2
    t.datetime "opened_at", null: false
    t.datetime "closed_at"
    t.decimal "close_price", precision: 15, scale: 5
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "stop_loss", precision: 15, scale: 5
    t.index ["strategy_id", "closed_at"], name: "index_positions_on_strategy_id_and_closed_at"
    t.index ["strategy_id", "ticket"], name: "index_positions_on_strategy_id_and_ticket", unique: true
    t.index ["strategy_id"], name: "index_positions_on_strategy_id"
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "endpoint", null: false
    t.string "p256dh_key", null: false
    t.string "auth_key", null: false
    t.string "user_agent"
    t.datetime "last_used_at"
    t.datetime "failed_at"
    t.integer "failure_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["endpoint"], name: "index_push_subscriptions_on_endpoint", unique: true
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "recovery_codes", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "code_digest", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "code_digest"], name: "index_recovery_codes_on_user_id_and_code_digest", unique: true
    t.index ["user_id"], name: "index_recovery_codes_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "strategies", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.string "symbol", default: "XAUUSD", null: false
    t.string "status", default: "draft", null: false
    t.string "direction", default: "both", null: false
    t.integer "grid_spacing_points"
    t.integer "grid_levels"
    t.decimal "initial_lot", precision: 10, scale: 2, null: false
    t.string "lot_mode", default: "fixed", null: false
    t.decimal "lot_multiplier", precision: 6, scale: 2
    t.decimal "basket_take_profit", precision: 15, scale: 2
    t.decimal "basket_stop_loss", precision: 15, scale: 2
    t.integer "max_positions", null: false
    t.decimal "max_exposure_lots", precision: 10, scale: 2, null: false
    t.decimal "max_drawdown_percent", precision: 5, scale: 2
    t.decimal "min_margin_level_percent", precision: 8, scale: 2
    t.integer "max_spread_points"
    t.datetime "started_at"
    t.datetime "stopped_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "category", default: "grid", null: false
    t.integer "trailing_stop_points"
    t.integer "trailing_activation_points"
    t.integer "trailing_step_points"
    t.index ["user_id", "category"], name: "index_strategies_on_user_id_and_category"
    t.index ["user_id", "status"], name: "index_strategies_on_user_id_and_status"
    t.index ["user_id", "symbol"], name: "index_strategies_one_running_per_symbol", unique: true, where: "((status)::text = 'running'::text)"
    t.index ["user_id"], name: "index_strategies_on_user_id"
    t.check_constraint "category::text <> 'grid'::text OR grid_spacing_points IS NOT NULL AND grid_levels IS NOT NULL", name: "grid_strategies_have_a_grid"
    t.check_constraint "category::text <> 'trailing'::text OR trailing_stop_points IS NOT NULL", name: "trailing_strategies_have_a_distance"
  end

  create_table "terminal_connections", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "api_token_id", null: false
    t.bigint "strategy_id"
    t.string "ea_version"
    t.string "broker"
    t.string "account_login"
    t.string "symbol", default: "XAUUSD", null: false
    t.decimal "bid", precision: 15, scale: 5
    t.decimal "ask", precision: 15, scale: 5
    t.integer "spread_points"
    t.datetime "last_report_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token_id"], name: "index_terminal_connections_on_api_token_id", unique: true
    t.index ["strategy_id"], name: "index_terminal_connections_on_strategy_id"
    t.index ["user_id"], name: "index_terminal_connections_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.text "otp_secret"
    t.datetime "otp_enabled_at"
    t.bigint "otp_last_used_step"
    t.jsonb "notification_preferences", default: {}, null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "worker_nodes", force: :cascade do |t|
    t.string "name", null: false
    t.string "hostname", null: false
    t.string "region"
    t.string "status", default: "offline", null: false
    t.integer "max_instances", default: 0, null: false
    t.string "agent_version"
    t.datetime "last_heartbeat_at"
    t.text "last_error"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_worker_nodes_on_name", unique: true
    t.index ["status"], name: "index_worker_nodes_on_status"
  end

  add_foreign_key "account_snapshots", "strategies"
  add_foreign_key "account_snapshots", "users"
  add_foreign_key "account_states", "strategies"
  add_foreign_key "account_states", "users"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "broker_credentials", "users"
  add_foreign_key "events", "users"
  add_foreign_key "mt5_instance_events", "mt5_instances"
  add_foreign_key "mt5_instance_events", "users"
  add_foreign_key "mt5_instances", "api_tokens", on_delete: :nullify
  add_foreign_key "mt5_instances", "strategies"
  add_foreign_key "mt5_instances", "users"
  add_foreign_key "mt5_instances", "worker_nodes"
  add_foreign_key "notifications", "users"
  add_foreign_key "orders", "strategies"
  add_foreign_key "positions", "strategies"
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "recovery_codes", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "strategies", "users"
  add_foreign_key "terminal_connections", "api_tokens"
  add_foreign_key "terminal_connections", "strategies"
  add_foreign_key "terminal_connections", "users"
end
