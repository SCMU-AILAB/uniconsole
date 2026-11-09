-- 邮箱注册改为直接成为观察者（不再需要审核），去掉审核标记
ALTER TABLE members DROP COLUMN pending_approval;
