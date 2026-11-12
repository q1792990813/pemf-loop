_ENCRYPT_=0    --LUA脚本加密

XGUSFunction = {
    write = 0x82,
    read = 0x83,
}

XGUS = {
    port = 1,       --端口号
    _runner = nil,
    head = 0x5AA5,  --帧头
    func = 0,       --命令
    addr = 0,       --地址
    count = 0,      --个数
    req = nil,      --请求数据
    crc = false,    --crc
    resp = false,   --写应答
}

--[[
创建新的XGUS实例
head 帧头
port 对应串口号
crc  对应CRC校验
resp 对应写应答
--]]
function XGUS:new(head,port,crc,resp)
    local obj = {}
    setmetatable(obj,self)
    self.__index = self
    obj.head = head or 0x5AA5
    obj.port = port or 0
    obj.crc = crc or false
    obj.resp = resp or false
    obj.timeout = 100  -- recv wait timeout (ms)

    obj.recvMsg = self.recv
    obj.sendMsg = self.send

    return obj
end

--延时
function XGUS:wait(when)
    local tickstart = get_tick_count()
    while when()~=true do
        local diff = get_tick_count()-tickstart
        if (diff<0) then diff = 0xFFFFFFFF-tickstart-diff+1 end
        if diff>self.timeout then
            return false
        end
        coroutine.yield()
    end
    
    return true
end

--串口发送
function XGUS:send(resp)

    if self.crc == true then
        local count = #resp
        local datas = XGUS:Copy(resp)
        table.remove(datas,1)
        table.remove(datas,1)
        table.remove(datas,1)
        local crc = XGUS:crc(datas)  -- CRC over CMD+ADDR+DATA (exclude head/len)
        resp[count+1] = crc & 0xff
        resp[count+2] = (crc >> 8) & 0xff
    end

    uart_send(self.port,resp)
end

-- 主动写寄存器到对端 (屏 -> MCU)
-- data: number=1字, 或 uint16 数组
function XGUS:dataSend(addr, data)
    if type(addr) ~= 'number' then
        print('XGUS:dataSend addr type error')
        return
    end
    if type(data) ~= 'table' and type(data) ~= 'number' then
        print('XGUS:dataSend data type error')
        return
    end

    local send_buff = {}
    send_buff[1] = (self.head >> 8) & 0xFF
    send_buff[2] = self.head & 0xFF
    send_buff[3] = 1 + 2 + ((type(data) == 'table') and (#data * 2) or 2)
    send_buff[4] = 0x82
    send_buff[5] = (addr >> 8) & 0xFF
    send_buff[6] = addr & 0xFF
    if type(data) == 'number' then
        send_buff[7] = (data >> 8) & 0xFF
        send_buff[8] = data & 0xFF
    else
        for i = 1, #data do
            send_buff[5 + i * 2] = (data[i] >> 8) & 0xFF
            send_buff[6 + i * 2] = data[i] & 0xFF
        end
    end
    self:sendMsg(send_buff)
end

--crc校验计算
function XGUS:crc(data_bytes)

    local function bit_xor(a, b)
        local res, p = 0, 1
        while a > 0 or b > 0 do
            if (a % 2) ~= (b % 2) then res = res + p end
            a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
        end
        return res
    end

    local function bit_and(a, b)
        local res, p = 0, 1
        while a > 0 and b > 0 do
            if (a % 2 == 1) and (b % 2 == 1) then res = res + p end
            a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
        end
        return res
    end

    local function bit_rshift(a, n)
        for _ = 1, n do a = math.floor(a / 2) end
        return a
    end

    local crc = 0xFFFF
    for _, byte in ipairs(data_bytes) do
        crc = bit_xor(crc, byte)
        for _ = 1, 8 do
            if bit_and(crc, 1) ~= 0 then
                crc = bit_rshift(crc, 1)
                crc = bit_xor(crc, 0xA001)
            else
                crc = bit_rshift(crc, 1)
            end
        end
    end
    return crc  -- Modbus CRC16, wire order: low byte then high byte
end

--表浅拷贝
function XGUS:Copy(original)
    local copy = {}
    for k, v in pairs(original) do
        copy[k] = v
    end
    return copy
end

--主动读串口数据
function XGUS:recv()
    local msgok = (self.crc == false)

    if uart_rxsize(self.port)<=0 then
        return false
    end

    if self:wait(function() return uart_rxsize(self.port)>=6 end)~=true then
        uart_rxclear(self.port)
        return false
    end

    local req = uart_recv(self.port,6)

    -- 勿改写 self.head: 噪声/错帧会污染后续主动发送的帧头(曾出现 E0 E0)
    local cmd_head = (req[1] << 8) | req[2]
    self.count = req[3]
    self.func = req[4]
    self.addr = (req[5] << 8) | req[6]

    if cmd_head ~= self.head or (self.func ~= 0x82 and self.func ~= 0x83) then
        -- 只丢掉 1 字节做重新同步, 勿清空整缓冲(会误删后续 Magnetic 帧)
        if uart_rxsize(self.port) > 0 then
            uart_recv(self.port, 1)
        end
        return false
    end

    local totoalSize = 3 + self.count
    local remainSize = totoalSize - 6
    if remainSize < 0 then
        return false
    end

    if self:wait(function() return uart_rxsize(self.port)>=remainSize end)
    then
        if remainSize > 0 then
            local req_remain = uart_recv(self.port,remainSize)
            local count = 6
            for k,v in ipairs(req_remain) do
                count = count+1
                req[count] = v
            end
        end
    else
        uart_rxclear(self.port)
        return false
    end
    self.req = req

    -- 成功收完一帧后不要 uart_rxclear:
    -- MCU 会连续发 Magnetic(0x100F)+Magnetic2(0x1014), 清缓冲会丢掉第二帧

    if self.crc == true then
        local crc_req = req[#req - 1] | (req[#req] << 8)  -- lo | hi<<8
        local str = XGUS:Copy(req)
        table.remove(str, #str)
        table.remove(str, #str)
        table.remove(str, 1)
        table.remove(str, 1)
        table.remove(str, 1)

        local crc_check = XGUS:crc(str)
        if crc_check == crc_req then
            msgok = true
        end
    else
        msgok = true
    end

    return msgok
end

--指令判断执行(检查)
function XGUS:processMsg()

    local func = self.func
    local write_count = (self.count - ((self.crc == true) and 5 or 3))//2

    if func == XGUSFunction.write then  --写
        local datas = {}

        for i = 1, write_count do
            datas[i] = self.req[5+i*2]<<8 | self.req[6+i*2] -- 解析写入数据
        end

        -- 用户寄存器默认 set_array; 回调返回 true 表示已自行处理(如温度 float)
        if self.addr >= 0x1000 then
            if not self:on_cmd_resp_xgus(self.addr, write_count, 1, datas) then
                set_array(VT_LW, self.addr, datas)
            end
        else
            self:on_cmd_resp_xgus(self.addr, write_count, 1, datas)
        end

        if self.resp == true then  --写应答
            uart_send(self.port, {((self.head)>>8),(self.head&0xFF),0x03,0x82,0x4F,0x4B})
        end

    elseif func == XGUSFunction.read then  --读

        if self.addr >= 0x1000 then
            if not self:on_cmd_resp_xgus(self.addr, self.req[7], 0, nil) then
                local datas = {((self.head)>>8),(self.head&0xFF),(((self.crc == true) and 6 or 4)+self.req[7]*2),0x83,(self.addr>>8),(self.addr&0xFF),(self.req[7]*2)}
                for i = 1, self.req[7] do
                    local num = get_uint16(VT_LW, self.addr+(i-1))
                    datas[6+i*2] = num>>8
                    datas[7+i*2] = num&0xFF
                end
                self:sendMsg(datas)
            end
        else
            self:on_cmd_resp_xgus(self.addr, self.req[7], 0, nil)
        end
    end
end

--[[
  读写回调 (可在 main.lua 中覆盖)
  addr  寄存器地址
  count 字数
  wr    0=读 1=写
  data  写时为 uint16 数组; 读时为 nil
  返回 true = 已处理, 跳过默认 set_array/读回包
--]]
function XGUS:on_cmd_resp_xgus(addr, count, wr, data)
    return false
end


--用户定时调用此接口
--使用协程可以打断或恢复任务，防止阻塞主线程
--方便执行耗时的任务流程
function XGUS:run()
    if self._runner == nil or coroutine.status(self._runner) == 'dead' then
        self._runner = coroutine.create(function() self:_run() end)
    end
    coroutine.resume(self._runner)
end

--循环取消息执行，仅内部使用
function XGUS:_run()
    while(true) do
        if self:recvMsg() then
          self:processMsg()
        else
          coroutine.yield()
        end
    end
end



