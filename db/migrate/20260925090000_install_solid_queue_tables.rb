# Puts Solid Queue's tables in the primary database.
#
# Production gives Solid Queue a database of its own, loaded straight from
# db/queue_schema.rb (see config/database.yml). Development cannot: the Local
# MT5 runtime requires Rails, the job runner and the terminals in one
# container, so the supervisor rides inside Puma and queues against the one
# development database — which therefore needs these tables.
#
# The table definitions are replayed from db/queue_schema.rb rather than
# copied, so a Solid Queue upgrade that regenerates the schema file cannot
# leave this migration silently describing older tables.
class InstallSolidQueueTables < ActiveRecord::Migration[8.0]
  def up
    schema = File.read(Rails.root.join("db/queue_schema.rb"))
    body = schema[/\A\s*ActiveRecord::Schema\[[\d.]+\]\.define\([^)]*\)\s+do\n(.*)\nend\s*\z/m, 1]
    raise "db/queue_schema.rb no longer looks like a schema file" if body.nil?

    instance_eval(body)
  end

  def down
    # Children before parents: everything hangs off jobs and batches.
    drop_table :solid_queue_batch_executions
    drop_table :solid_queue_blocked_executions
    drop_table :solid_queue_claimed_executions
    drop_table :solid_queue_failed_executions
    drop_table :solid_queue_ready_executions
    drop_table :solid_queue_recurring_executions
    drop_table :solid_queue_scheduled_executions
    drop_table :solid_queue_batches
    drop_table :solid_queue_jobs
    drop_table :solid_queue_pauses
    drop_table :solid_queue_processes
    drop_table :solid_queue_recurring_tasks
    drop_table :solid_queue_semaphores
  end
end
