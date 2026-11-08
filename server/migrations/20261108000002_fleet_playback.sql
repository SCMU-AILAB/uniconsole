-- 联调时间轴播放：开始播放的时刻（减去起播偏移），NULL = 未播放。前端用 now - playback_started_at 画播放头
ALTER TABLE fleet_sessions ADD COLUMN playback_started_at TIMESTAMPTZ;
