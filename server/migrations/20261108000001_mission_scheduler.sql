-- 任务调度器：按 schedule 自动生成的排期标记为 auto，任务修改后重新生成（手动排期不受影响）
ALTER TABLE schedule_entries ADD COLUMN auto BOOLEAN NOT NULL DEFAULT FALSE;
CREATE UNIQUE INDEX schedule_entries_auto_unique ON schedule_entries (mission_id, starts_at) WHERE auto;
