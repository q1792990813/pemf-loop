--============================================================================
-- PMST Loop 治疗控制台 - VisualHMI LUA
-- 硬件: DC10768DH080_1V01_0X(TCN) 8" IPS 1024x768 / 256Mbit
-- 接口: RS232 串口0  115200 8N1  <->  STM32 主控
-- 协议: XGUS (迪文风格) 帧头55AA / 写0x82 读0x83 / 无CRC
-- 基础: 基于 index.html 界面 (启动/暂停/停止/急停)
-- 方案: 方案页为自定义表格 (8行x频率+时间), 启动后从上向下依次执行
--============================================================================
_ENCRYPT_ = 0

VT_LW = 1    -- 本地变量 / 数据映射寄存器
VT_RW = 2    -- FLASH 掉电保存
-- 防 on_update 重入: 脚本内 set_* 寄存器前先置 0, 写完再置 1;
-- on_update 入口若为 0 则直接 return
EN_ON_UPDATE_API_CB = 1
_EN_SET_DATA_ = false

local function update_lock()
    EN_ON_UPDATE_API_CB = 0
end

local function update_unlock()
    EN_ON_UPDATE_API_CB = 1
end

----------------------------------------------------------------------------
-- 寄存器映射 (与 STM32 / index.html 状态一一对应)
-- 全部使用 LW 字地址, 16bit
----------------------------------------------------------------------------
REG = {
    -- 运行控制
    BTN_CONTROL = 0x1000,  -- 命令: 0启动 1暂停 2播放(恢复) 3停止
    STATUS      = 0x1001,  -- 状态: 0启动 1暂停 2恢复播放 3完成 99空闲
    INTENSITY   = 0x1004,  -- 强度 0~100 %
    DURATION    = 0x1005,  -- 设定时长 分钟 5~30 (单次模式 = 总时长; 序列模式 = 当前行)
    REMAIN_SEC     = 0x1006,  -- 进度条当前值 (剩余秒数, 从MAX减到0)  必须用 uint16
    REMAIN_MIN_SEC = 0x1008,  -- 进度条最大值 (本次总秒数)
    TEMP_X10    = 0x100A,  -- 温度: MCU写1字=℃×100; 屏 set_float 占 LW100A+100B
    ALARM       = 0x100C,  -- 告警位: bit0过温 bit1通道 bit2硬件
    PAGE        = 0x100D,  -- 当前页: 0治疗 1方案 2设置
    REMAIN_MAX_SEC = 0x100E,  -- 进度条最小值 (固定0)
    Magnetic    = 0x100F,  -- 磁场1: MCU写 int32=H×1000 大端4字节; 屏 /1000 set_float
    Magnetic2   = 0x1014,  -- 磁场2: 同上 (占 LW1014/1015)
    ANIMATION   = 0x1020,  -- 动画
	MUSIC_IDX    = 0x1042,  -- 音乐曲目索引(勿与 STATUS 0x1001 冲突)
    -- 自定义方案表 (8 行, 每行设频率+时间, 从上向下依次执行)
    TBL_FREQ    = 0x1210,  -- [0x1210..0x1217] 各行频率 Hz
    TBL_TIME    = 0x1218,  -- [0x1218..0x121F] 各行时长 分钟 (0=跳过该行)
    SEQ_COUNT   = 0x1220,  -- 有效行数 1~8
    SEQ_CUR     = 0x1221,  -- 当前执行行 0=无 1~8
    SEQ_TOTAL   = 0x1222,  -- 方案总时长 秒
    SEQ_REMAIN  = 0x1223,  -- 方案总剩余 秒
    ROW_STATE   = 0x1230,  -- [0x1230..0x1237] 各行状态 0空闲 1执行中
    -- 字符串区
    CLOCK_STR   = 0x1100,  -- 时钟显示 "HH:MM" (备用; 一般使用 RTC 控件)
    STATUS_STR  = 0x1120,  -- 状态文本
    RING_STR    = 0x1140,  -- 倒计时 "MM:SS" (序列模式 = 当前行剩余)
    TOTAL_STR   = 0x1160,  -- 序列总剩余 "MM:SS"

	-- 音频互斥开关 (UI); 串口: 55 AA 05 82 13 00 00 vv (1内部/0外部)
	-- 硬件内外接反: MCU PB4 低=内部(默认), 高=外部; 协议语义不变
	SET_INTERNAL_AUDIO   = 0x1301,
	SET_EXTERNAL_AUDIO   = 0x1300,
}

local g = {
    remaining  = 15 * 60,
    total_sec  = 15 * 60, -- 本次治疗总秒数 (进度条 MAX)
    duration   = 15,
    running    = false,
    paused     = false,
    timer_on   = false,
    ready      = false,
    music_on   = false,
    music_file = '',
    music_tick = 0,
    music_len  = 58,
    seq_active = false,
    seq_cnt    = 0,
    seq_pos    = -1,
    seq_total  = 0,
    seq_remain = 0,
}

-- Lua5.1兼容版 HH:MM:SS
local function fmt_hhmmss(sec)
    if sec < 0 then sec = 0 end
    local h = math.floor(sec / 3600)
    local rem = sec % 3600
    local m = math.floor(rem / 60)
    local s = rem % 60
    return string.format('%02d:%02d:%02d', h, m, s)
end


local function fmt_mmss(sec)
    if sec < 0 then sec = 0 end
    local m = math.floor(sec / 60)
    local s = sec % 60
    return string.format('%02d:%02d', m, s)
end


-- 是否处于倒计时运行 (启动中 / 恢复播放中)
local function is_playing()
    local st = get_uint16(VT_LW, REG.STATUS)
    return st == 0 or st == 2
end

-- 进度条范围: 启动时写一次 MIN/MAX (UINT32, 地址已隔开互不覆盖)
local function sync_progress_range()
    local total = g.total_sec
    if total < 1 then total = 1 end
    set_uint32(VT_LW, REG.REMAIN_MIN_SEC, 0)       -- LW100A 最小
    set_uint32(VT_LW, REG.REMAIN_MAX_SEC, total)   -- LW1008 最大
end

-- 进度条当前值: LW1006 = 剩余秒数 (从 MAX 减到 0)
local function sync_progress()
    local total = g.total_sec
    if total < 1 then total = 1 end
    local cur = g.remaining
    if cur < 0 then cur = 0 end
    if cur > total then cur = total end
    set_uint32(VT_LW, REG.REMAIN_SEC, cur)         -- LW1006 当前(剩余)
end

local function sync_display(notify)
    if notify == false then set_notify(0) end
    sync_progress()
    set_string(VT_LW, REG.RING_STR, fmt_hhmmss(g.remaining))
    if g.seq_active or g.seq_total > 0 then
        set_uint16(VT_LW, REG.SEQ_REMAIN, g.seq_remain)
        set_string(VT_LW, REG.TOTAL_STR, fmt_hhmmss(g.seq_remain))
    end
    local st = get_uint16(VT_LW, REG.STATUS)
    local txt = 'Idle'
    if st == 0 then txt = 'Starting'
    elseif st == 1 then txt = 'Paused'
    elseif st == 2 then txt = 'Play resumed'
    elseif st == 3 then txt = 'Finished'
    elseif st == 99 then txt = 'Idle'
    end

    set_string(VT_LW, REG.STATUS_STR, txt)
    if notify == false then set_notify(1) end
end

local function anim_set(on)
    set_uint16(VT_LW, REG.ANIMATION, on and 1 or 0)
end

-- 未选曲目则无效 (MUSIC_IDX==0)
local function invalid_music()
    local musicIndex = get_uint16(VT_LW, REG.MUSIC_IDX)
    -- print("music index = ", musicIndex)
    if musicIndex == 0 then
        return true
    end
    return false
end

local function music_start()
    local musicIndex = get_uint16(VT_LW, REG.MUSIC_IDX)
    g.music_file = string.format("3:/sound/%d.mp3", musicIndex)
    play_sound(g.music_file)
    g.music_on = true
    g.music_tick = 0
end

local function music_stop()
    g.music_on = false
    g.music_tick = 0
    stop_sound()
end

-- 循环: 播完或超过曲长时重播同一首 (仅治疗进行中)
local function music_loop_tick()
    if not g.music_on or g.paused then return end
    if not is_playing() then return end
    g.music_tick = g.music_tick + 1
    -- SysSndState LW0142 bit6=1 表示播放结束
    local snd = get_uint16(VT_LW, 0x0142)
    local ended = ((snd >> 6) & 0x01) == 0x01
    if ended or g.music_tick >= g.music_len then
        g.music_tick = 0
        if ended then
            set_uint16(VT_LW, 0x0142, snd & 0xFFBF)
        end
        if g.music_file ~= '' then
            play_sound(g.music_file)
        end
    end
end

-- 倒计时结束: 停动画+停音乐 (调用方须已 update_lock, 本函数不 unlock)
local function finish_treatment()
    stop_timer(0)
    g.timer_on = false
    g.running = false
    g.paused = false
    g.remaining = 0
    anim_set(false)
    music_stop()
    set_uint16(VT_LW, REG.BTN_CONTROL, 0)
    set_uint16(VT_LW, REG.STATUS, 3)
    sync_progress()   -- 当前值减到 0
    sync_display(true)
end

----------------------------------------------------------------------------
-- 自定义方案表 (序列) 相关
----------------------------------------------------------------------------
local function row_valid(i)
    -- 第 i 行 (0基) 是否可执行; 返回 ok, 频率, 分钟
    local f = get_uint16(VT_LW, REG.TBL_FREQ + i)
    local t = get_uint16(VT_LW, REG.TBL_TIME + i)
    if f > 3000 then f = 3000 end
    if t > 30 then t = 30 end
    if f > 0 and t > 0 then
        return true, f, t
    end
    return false, 0, 0
end

local function seq_calc_total(cnt)
    -- 统计前 cnt 行的总秒数
    local total = 0
    for i = 0, cnt - 1 do
        local ok, f, t = row_valid(i)
        if ok then total = total + t * 60 end
    end
    return total
end

local function seq_clear_states()
    for i = 0, 7 do
        set_uint16(VT_LW, REG.ROW_STATE + i, 0)
    end
    set_uint16(VT_LW, REG.SEQ_CUR, 0)
end

local function seq_load_row(i)
    -- 载入第 i 行 (0基): 频率按当前模式约束, 启动本行倒计时
    local ok, f, t = row_valid(i)
    if not ok then return false end
    --local mode = get_uint16(VT_LW, REG.MODE)
    --if mode == 0 then
    --    if f > 150 then f = 150 end        -- MT: 1~150
    --else
    --    if f < 100 then f = 1000 end       -- ST: 1000~3000
    --    if f > 3000 then f = 3000 end
    --end
    --set_uint16(VT_LW, REG.FREQ, f)
    set_uint16(VT_LW, REG.DURATION, t)
    g.duration = t
    g.remaining = t * 60
    g.seq_pos = i
    for r = 0, 7 do
        if r == i then
            set_uint16(VT_LW, REG.ROW_STATE + r, 1)
        else
            set_uint16(VT_LW, REG.ROW_STATE + r, 0)
        end
    end
    set_uint16(VT_LW, REG.SEQ_CUR, i + 1)
    return true
end

local function seq_next()
    -- 从当前行向下找下一个可执行行; 没有则返回 false (序列结束)
    local i = g.seq_pos + 1
    while i < g.seq_cnt do
        if seq_load_row(i) then
            return true
        end
        i = i + 1
    end
    return false
end

local function seq_refresh_total()
    -- 待机时编辑方案表 => 实时刷新总时长/总剩余显示
    update_lock()
    local cnt = get_uint16(VT_LW, REG.SEQ_COUNT)
    if cnt < 1 then cnt = 1 end
    if cnt > 8 then cnt = 8 end
    local total = seq_calc_total(cnt)
    g.seq_total = total
    g.seq_remain = total
    g.remaining = total
    set_notify(0)
    -- 不回写 SEQ_COUNT, 避免 on_update 重入
    set_uint16(VT_LW, REG.SEQ_TOTAL, total)
    set_uint16(VT_LW, REG.SEQ_REMAIN, total)
    set_uint32(VT_LW, REG.REMAIN_SEC, total)
    set_string(VT_LW, REG.RING_STR, fmt_hhmmss(total))
    set_string(VT_LW, REG.TOTAL_STR, fmt_hhmmss(total))
    set_notify(1)
    update_unlock()
end

-- BTN 0: 启动 (仅空闲99 / 完成3 可启动)
local function do_start()
    update_lock()
    local st = get_uint16(VT_LW, REG.STATUS)
    if st ~= 99 and st ~= 3 then
        update_unlock()
        return
    end
    local flag = invalid_music()
    if flag then
        update_unlock()
        return
    end

    local hour = get_uint16(VT_LW, 0x1040)
    local minu = get_uint16(VT_LW, 0x1041)

    if hour > 0 or minu > 0 then
        g.remaining = hour * 3600 + minu * 60
    else
        g.remaining = 0
        g.total_sec = 0
        set_uint32(VT_LW, REG.REMAIN_MIN_SEC, 0)
        set_uint32(VT_LW, REG.REMAIN_SEC, 0)
        set_uint32(VT_LW, REG.REMAIN_MAX_SEC, 10)
        update_unlock()
        return
    end

    g.total_sec = g.remaining
    -- 进度条: MIN=0, MAX=总秒, 当前=总秒 (之后每秒递减)
    sync_progress_range()
    set_uint32(VT_LW, REG.REMAIN_SEC, g.total_sec)

    music_start()

    g.running = true
    g.paused = false
    set_uint16(VT_LW, REG.STATUS, 0)   -- 启动中
    anim_set(true)
    set_uint16(VT_LW, REG.BTN_CONTROL, 1)
    sync_display(true)
    stop_timer(0)
    start_timer(0, 1000, 0, 0)
    g.timer_on = true
    update_unlock()
end

-- BTN 1: 暂停 (仅启动0 / 恢复播放2 可暂停)
local function do_pause()
    update_lock()
    local st = get_uint16(VT_LW, REG.STATUS)
    if st ~= 0 and st ~= 2 then
        update_unlock()
        return
    end
    g.paused = true
    g.running = true
    set_uint16(VT_LW, REG.STATUS, 1)   -- 暂停
    anim_set(false)
    set_uint16(VT_LW, REG.BTN_CONTROL, 2)
    stop_timer(0)
    g.timer_on = false
    pause_sound()
    sync_display(true)
    update_unlock()
end

-- BTN 2: 播放/恢复 (仅暂停1 可恢复)
local function do_resume()
    update_lock()
    local st = get_uint16(VT_LW, REG.STATUS)
    if st ~= 1 then
        update_unlock()
        return
    end
    g.paused = false
    g.running = true
    set_uint16(VT_LW, REG.STATUS, 2)   -- 恢复播放
    anim_set(true)
    set_uint16(VT_LW, REG.BTN_CONTROL, 1)
    start_timer(0, 1000, 0, 0)
    g.timer_on = true
    resume_sound()
    sync_display(true)
    update_unlock()
end

local function do_start_seq()
    update_lock()
    -- 启动自定义方案表 (空闲/完成时可启动)
    local st = get_uint16(VT_LW, REG.STATUS)
    if st ~= 99 and st ~= 3 then
        update_unlock()
        if st == 1 then do_resume() end
        return
    end
    local cnt = get_uint16(VT_LW, REG.SEQ_COUNT)
    if cnt < 1 then cnt = 1 end
    if cnt > 8 then cnt = 8 end
    local total = seq_calc_total(cnt)
    if total <= 0 then
        set_notify(0)
        set_string(VT_LW, REG.STATUS_STR, '方案表为空')
        set_notify(1)
        update_unlock()
        return
    end
    g.seq_active = true
    g.seq_cnt = cnt
    g.seq_total = total
    g.seq_remain = total
    g.seq_pos = -1
    set_notify(0)
    set_uint16(VT_LW, REG.SEQ_TOTAL, total)
    set_uint16(VT_LW, REG.SEQ_REMAIN, total)
    set_string(VT_LW, REG.TOTAL_STR, fmt_hhmmss(total))
    set_notify(1)
    if not seq_next() then
        g.seq_active = false
        update_unlock()
        return
    end
    g.total_sec = g.remaining
    sync_progress_range()
    set_uint32(VT_LW, REG.REMAIN_SEC, g.total_sec)
    g.running = true
    g.paused = false
    set_uint16(VT_LW, REG.STATUS, 0)   -- 启动中
    anim_set(true)
    music_start()
    sync_display(true)
    stop_timer(0)
    start_timer(0, 1000, 0, 0)
    g.timer_on = true
    update_unlock()
end

-- 调用方须已 update_lock
local function seq_finish()
    g.seq_active = false
    seq_clear_states()
    g.remaining = g.seq_total
    g.seq_remain = g.seq_total
    finish_treatment()  -- 停动画+停音乐+STATUS=3
end

-- BTN 3: 停止 -> 空闲99
local function do_stop()
    update_lock()
    stop_timer(0)
    g.timer_on = false
    g.running = false
    g.paused = false
    if g.seq_active then
        g.seq_active = false
        seq_clear_states()
        --g.remaining = g.seq_total
        --g.seq_remain = g.seq_total
    end
    set_notify(0)
    set_uint16(VT_LW, REG.BTN_CONTROL, 0)
    set_uint16(VT_LW, REG.SEQ_REMAIN, 0)
    set_string(VT_LW, REG.TOTAL_STR, fmt_hhmmss(0))
    set_notify(1)
    anim_set(false)
    music_stop()
    set_uint16(VT_LW, REG.STATUS, 99)  -- 空闲
    sync_display(false)
    update_unlock()
end

local function do_emergency()
    do_stop()
    change_screen(3)
end

local function do_reset_emergency()
    update_lock()
    set_uint16(VT_LW, REG.STATUS, 99)
    sync_display(true)
    update_unlock()
    change_screen(0)
end

-- 音频模式通知 MCU (单协议, 无CRC)
-- 帧: 55 AA 05 82 13 00 00 vv
--   vv=1 内部音频 (MCU: PB4 低, 硬件接反后的默认)
--   vv=0 外部音频 (MCU: PB4 高)
local function notify_audio_mode_to_mcu()
    local mode = get_uint16(VT_LW, REG.SET_INTERNAL_AUDIO)  -- 1内部 / 0外部
    if mode ~= 0 then mode = 1 end
    -- 协议语义不变; 电平极性由 MCU 按硬件接反处理
    uart_send(0, {0x55, 0xAA, 0x05, 0x82, 0x13, 0x00, 0x00, mode})
    print(string.format('[AUDIO] send 55 AA 05 82 13 00 00 %02X (1=内部/0=外部)', mode))
end

local function switch_audio_mode(vtype, addr)
    if addr == REG.SET_INTERNAL_AUDIO then
        update_lock()
        set_notify(0)  -- 禁止系统协议因 set_uint16 自动发串口
        local s = get_uint16(VT_LW, REG.SET_INTERNAL_AUDIO)
        if s == 0 then
            set_uint16(VT_LW, REG.SET_EXTERNAL_AUDIO, 1)
        else
            set_uint16(VT_LW, REG.SET_EXTERNAL_AUDIO, 0)
        end
        set_notify(1)
        update_unlock()
        notify_audio_mode_to_mcu()
    elseif addr == REG.SET_EXTERNAL_AUDIO then
        update_lock()
        set_notify(0)
        local s = get_uint16(VT_LW, REG.SET_EXTERNAL_AUDIO)
        if s == 0 then
            set_uint16(VT_LW, REG.SET_INTERNAL_AUDIO, 1)
        else
            set_uint16(VT_LW, REG.SET_INTERNAL_AUDIO, 0)
        end
        set_notify(1)
        update_unlock()
        notify_audio_mode_to_mcu()
    end
end
--============================================================================
function on_init()
    g.ready = false
    update_lock()
    dofile('XGUS.lua')
    uart_setup(0,115200,8,0,0)
    -- 主串口交给 Lua 自由协议 (否则系统协议可能抢发/改写报文)
    if set_free_protocol ~= nil then
        set_free_protocol(1)
    end
    -- XGUS: 帧头55AA, 串口0, CRC关, 写应答关(避免 OK 回包干扰连发的 Magnetic2)
    xus = XGUS:new(0x55AA, 0, false, false)

    -- 温度: MCU 写 LW100A (1字=℃×100) -> on_cmd_resp_xgus -> set_float 显示
    function XGUS:on_cmd_resp_xgus(addr, count, wr, data)
        local op = (wr == 1) and 'WRITE' or 'READ'
        print(string.format('[XGUS] %s addr=0x%04X count=%d', op, addr, count or 0))
        if wr == 1 and data ~= nil then
            local hex = ''
            for i = 1, #data do
                hex = hex .. string.format('%04X ', data[i])
            end
            print('[XGUS] write data: ' .. hex)
        end

        if addr == REG.TEMP_X10 then
            if wr == 1 and data ~= nil and data[1] ~= nil then
                local temp = data[1] / 100.0
                if temp < 0 then temp = 0 end
                if temp > 99.99 then temp = 99.99 end
                update_lock()
                set_float(VT_LW, REG.TEMP_X10, temp)
                update_unlock()
                print(string.format('[XGUS] TEMP set %.2f C (raw=%d)', temp, data[1]))
                return true
            elseif wr == 0 then
                -- 读温度: 回包 1 字 = ℃×100
                local t = get_float(VT_LW, REG.TEMP_X10)
                local raw = math.floor(t * 100 + 0.5)
                if raw < 0 then raw = 0 end
                if raw > 65535 then raw = 65535 end
                local n = count or 1
                local datas = {
                    (self.head >> 8), (self.head & 0xFF),
                    ((self.crc and 6 or 4) + n * 2),
                    0x83, (addr >> 8), (addr & 0xFF), (n * 2)
                }
                datas[8] = (raw >> 8) & 0xFF
                datas[9] = raw & 0xFF
                for i = 2, n do
                    datas[6 + i * 2] = 0
                    datas[7 + i * 2] = 0
                end
                self:sendMsg(datas)
                print(string.format('[XGUS] TEMP read reply %.2f C (raw=%d)', t, raw))
                return true
            end
        elseif addr == REG.Magnetic or addr == REG.Magnetic2 then
            -- 55 AA 07 82 AddrH AddrL D3..D0  (int32 大端 = H×1000, 屏显示 H)
            -- Magnetic=0x100F / Magnetic2=0x1014
            if wr == 1 and data ~= nil and data[1] ~= nil then
                local hi = data[1] & 0xFFFF
                local lo = (data[2] ~= nil) and (data[2] & 0xFFFF) or 0
                local raw = (hi << 16) | lo
                if raw >= 0x80000000 then
                    raw = raw - 0x100000000  -- 有符号 int32
                end
                local mag = raw / 1000.0  -- 还原浮点磁感应强度
                update_lock()
                set_float(VT_LW, addr, mag)
                update_unlock()
                print(string.format('[XGUS] Magnetic set %.3f (raw=%d) @LW%04X', mag, raw, addr))
                return true
            elseif wr == 0 then
                local mag = get_float(VT_LW, addr)
                local v = math.floor(mag * 1000 + (mag >= 0 and 0.5 or -0.5))
                if v < 0 then v = v + 0x100000000 end
                v = v % 0x100000000
                local n = 2
                local datas = {
                    (self.head >> 8), (self.head & 0xFF),
                    ((self.crc and 6 or 4) + n * 2),
                    0x83, (addr >> 8), (addr & 0xFF), (n * 2)
                }
                datas[8] = (v >> 24) & 0xFF
                datas[9] = (v >> 16) & 0xFF
                datas[10] = (v >> 8) & 0xFF
                datas[11] = v & 0xFF
                self:sendMsg(datas)
                print(string.format('[XGUS] Magnetic read reply %.3f @LW%04X', mag, addr))
                return true
            end
        end
        print('[XGUS] not handled by callback, use default')
        return false
    end
    set_notify(0)
    set_uint16(VT_LW, REG.BTN_CONTROL, 0)
    set_uint16(VT_LW, REG.STATUS, 99)          -- 空闲
    set_uint16(VT_LW, REG.ANIMATION, 0)
    set_uint16(VT_LW, REG.INTENSITY, 50)
    set_uint16(VT_LW, REG.DURATION, 15)
    set_uint32(VT_LW, REG.REMAIN_MIN_SEC, 0)
    set_uint32(VT_LW, REG.REMAIN_MAX_SEC, 10)
    set_uint32(VT_LW, REG.REMAIN_SEC, 0)
    set_float(VT_LW, REG.TEMP_X10, 0)       -- 初始温度 36.5C
    set_float(VT_LW, REG.Magnetic, 0)          -- 初始磁场1
    set_float(VT_LW, REG.Magnetic2, 0)         -- 初始磁场2
    set_uint16(VT_LW, REG.ALARM, 0)
    set_uint16(VT_LW, REG.PAGE, 0)
    set_uint16(VT_LW, REG.SET_INTERNAL_AUDIO, 1)
    set_uint16(VT_LW, REG.SET_EXTERNAL_AUDIO, 0)
    notify_audio_mode_to_mcu()  -- 上电默认: 内部开/外部关
    local TBL_DEF = { {10, 5}, {25, 5}, {50, 5}, {100, 5} }
    for i = 0, 7 do
        local f = 0
        local t = 0
        if i < 4 then
            f = TBL_DEF[i + 1][1]
            t = TBL_DEF[i + 1][2]
        end
        set_uint16(VT_LW, REG.TBL_FREQ + i, f)
        set_uint16(VT_LW, REG.TBL_TIME + i, t)
        set_uint16(VT_LW, REG.ROW_STATE + i, 0)
    end
    set_uint16(VT_LW, REG.SEQ_COUNT, 4)
    set_uint16(VT_LW, REG.SEQ_CUR, 0)
    set_uint16(VT_LW, REG.SEQ_TOTAL, 20 * 60)
    set_uint16(VT_LW, REG.SEQ_REMAIN, 20 * 60)
    set_string(VT_LW, REG.CLOCK_STR, '00:00:00')
    set_string(VT_LW, REG.STATUS_STR, 'Idel')
    set_string(VT_LW, REG.RING_STR, '00:00:00')
    set_string(VT_LW, REG.TOTAL_STR, '00:00:00')
    set_notify(1)

    g.duration = 0
    g.remaining = 0
    g.total_sec = 0
    g.running = false
    g.paused = false
    g.timer_on = false
    g.seq_active = false
    g.seq_cnt = 4
    g.seq_pos = -1
    g.seq_total = 0
    g.seq_remain = 0
    g.music_on = false
    g.music_file = ''
    g.music_tick = 0
    update_unlock()
    g.ready = true
end

function on_run(screen)
    _EN_SET_DATA_ = true
    xus:run()
    _EN_SET_DATA_ = false
end

-- 串口温度已改由 XGUS (on_run -> xus:run -> on_cmd_resp_xgus) 接收, 不再用自定义 AA55 帧

-- 音频播完回调(若固件支持): 治疗中则循环同一首
function on_audio_callback(state)
    if g.music_on and (not g.paused) and is_playing() then
        if g.music_file ~= '' then
            play_sound(g.music_file)
            g.music_tick = 0
        end
    end
end

function on_timer(timer_id)
    update_lock()
    if timer_id == 0 then
        -- STATUS 0/2 时倒计时
        if is_playing() and g.remaining > 0 then
            g.remaining = g.remaining - 1
            if g.seq_active and g.seq_remain > 0 then
                g.seq_remain = g.seq_remain - 1
            end
            set_notify(0)
            sync_progress()   -- 进度条当前值递减
            set_string(VT_LW, REG.RING_STR, fmt_hhmmss(g.remaining))
            if g.seq_active then
                set_uint16(VT_LW, REG.SEQ_REMAIN, g.seq_remain)
                set_string(VT_LW, REG.TOTAL_STR, fmt_hhmmss(g.seq_remain))
            end
            set_notify(1)
            music_loop_tick()
            if g.remaining == 0 then
                if g.seq_active then
                    if seq_next() then
                        g.total_sec = g.remaining
                        set_notify(0)
                        sync_progress()
                        set_string(VT_LW, REG.RING_STR, fmt_hhmmss(g.remaining))
                        set_notify(1)
                    else
                        seq_finish()
                    end
                else
                    finish_treatment()
                end
            end
        end
    end
    update_unlock()
end

function on_update(slave, vtype, addr)
    if EN_ON_UPDATE_API_CB == 0 then return end
    if not g.ready then return end
    if vtype ~= VT_LW then return end
    switch_audio_mode(vtype, addr)

    -- BTN_CONTROL: 0启动 1暂停 2播放(恢复) 3停止
    if addr == REG.BTN_CONTROL then
        local cmd = get_uint16(vtype, addr)
        if cmd == 0 then
            do_start()
        elseif cmd == 1 then
            do_pause()
        elseif cmd == 2 then
            do_resume()
        elseif cmd == 3 then
            do_stop()
        end

    elseif addr == REG.DURATION then
        local st = get_uint16(VT_LW, REG.STATUS)
        if st == 99 or st == 3 then
            update_lock()
            g.duration = get_uint16(vtype, addr)
            if g.duration < 5 then g.duration = 5 end
            if g.duration > 30 then g.duration = 30 end
            g.remaining = g.duration * 60
            sync_display(false)
            update_unlock()
        end

    elseif addr == REG.TEMP_X10 then
        local t = get_float(vtype, addr)
        if t >= 45.0 then
            local alarm = get_uint16(VT_LW, REG.ALARM)
            -- update_lock(); set_uint16(VT_LW, REG.ALARM, alarm | 0x01); update_unlock()
            -- do_emergency()
        end

    elseif (addr >= REG.TBL_FREQ and addr <= REG.TBL_FREQ + 7) or
           (addr >= REG.TBL_TIME and addr <= REG.TBL_TIME + 7) or
           addr == REG.SEQ_COUNT then
        local st = get_uint16(VT_LW, REG.STATUS)
        if st == 99 or st == 3 then
            seq_refresh_total()
        end
    end
end

function on_screen_change(screen)
    update_lock()
    set_notify(0)
    set_uint16(VT_LW, REG.PAGE, screen)
    set_notify(1)
    update_unlock()
end
