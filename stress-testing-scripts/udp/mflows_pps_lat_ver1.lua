local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local ts     = require "timestamping"
local filter = require "filter"
local hist   = require "histogram"
local stats  = require "stats"
local timer  = require "timer"
local arp    = require "proto.arp"
local log    = require "log"

-- set addresses here
local DST_MAC		= nil -- resolved via ARP on GW_IP or DST_IP, can be overriden with a string here
local SRC_IP_BASE	= "10.0.0.10" -- actual address will be SRC_IP_BASE + random(0, flows)
local DST_IP		= "10.1.0.10"
local SRC_PORT		= 1234
local DST_PORT		= 319
local MAX_QUEUE_COUNT_PORT_82599ES 	= 64
-- answer ARP requests for this IP on the rx port
-- change this if benchmarking something like a NAT device
local RX_IP		= DST_IP
-- used to resolve DST_MAC
local GW_IP		= DST_IP
-- used as source IP to resolve GW_IP to DST_MAC
local ARP_IP	= SRC_IP_BASE

function configure(parser)
	parser:description("Generates UDP traffic and measure latencies. Edit the source to modify constants like IPs.")
	parser:argument("txDev0", "Device to transmit from (port 1)."):convert(tonumber)
	parser:argument("rxDev0", "Device to receive from (port 2)."):convert(tonumber)
	parser:argument("txDev1", "Device to transmit from (port 3)."):convert(tonumber)
        parser:argument("rxDev1", "Device to receive from (port 4)."):convert(tonumber)

	--parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000):convert(tonumber)
	parser:option("-r --rate", "Transm4it rate in Mbit/s."):default(0):convert(tonumber)
	parser:option("--rate_pps", "Transmit rate in PPS."):default(0):convert(tonumber)
	--parser:option("-f --flows", "Number of flows (randomized source IP)."):default(4):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("--sport", "UDP source port number."):default(SRC_PORT):convert(tonumber)
	parser:option("--dport", "UDP destination port number."):default(DST_PORT):convert(tonumber)
	parser:option("--queue_pair", "A queue pair number (TX/RX) to use on a NIC's port."):default(0):convert(tonumber)
	parser:option("--tstamp", "Enable(true)/Disable(false) packet hardware (NIC) timestamping"):default(false):convert(toboolean)
end

function master(args)
	txDev0 = device.config{port = args.txDev0, rxQueues = 3, txQueues = 3}
	rxDev0 = device.config{port = args.rxDev0, rxQueues = 3, txQueues = 3}
	txDev1 = device.config{port = args.txDev1, rxQueues = 3, txQueues = 3}
        rxDev1 = device.config{port = args.rxDev1, rxQueues = 3, txQueues = 3}
	src_port = args.sport
	dst_port = args.dport
	queue_count = 0
	
	device.waitForLinks()
	-- max 1kpps timestamping traffic timestamping
	-- rate will be somewhat off for high-latency links at low rates
	if args.queue_pair <= MAX_QUEUE_COUNT_PORT_82599ES - 1 then   
		if args.rate > 0 then
			txDev0:getTxQueue(args.queue_pair):setRate(args.rate - (args.size + 4) * 8 / 1000)
		elseif args.rate_pps > 0 then
			txDev0:getTxqueue(args.queue_pair):setRate(args.rate_pps - (args.size + 4) * 8 / 1000)
		else
			log:info("TxDev0: Flow rate is not specified!!!. Terminating... ")
			return
		end
		
		if args.tstamp then
			mg.startTask("timerSlave", txDev0:getTxQueue(args.queue_pair), rxDev0:getRxQueue(args.queue_pair), args.size, args.sport, args.dport)
		else
			mg.startTask("loadSlave", txDev0:getTxQueue(args.queue_pair), rxDev0, args.size, args.sport, args.dport)
		end
		
		arp.startArpTask{
               		 -- run ARP on both ports
               		 { rxQueue = rxDev0:getRxQueue(args.queue_pair), txQueue = rxDev0:getTxQueue(args.queue_pair), ips = RX_IP },
               		 -- we need an IP address to do ARP requests on this interface
               		 { rxQueue = txDev0:getRxQueue(args.queue_pair), txQueue = txDev0:getTxQueue(args.queue_pair), ips = ARP_IP }
        	}


	elseif args.queue_pair > MAX_QUEUE_COUNT_PORT_82599ES - 1 then
		if args.rate > 0 then
                        txDev1:getTxQueue(args.queue_pair):setRate(args.rate - (args.size + 4) * 8 / 1000)
                elseif args.rate_pps > 0 then
                        txDev1:getTxqueue(args.queue_pair):setRate(args.rate_pps - (args.size + 4) * 8 / 1000)
                else
                        log:info("TxDev1: Flow rate is not specified!!!. Terminating... ")
                        return
                end

		if args.tstamp then
                        mg.startTask("timerSlave", txDev1:getTxQueue(args.queue_pair), rxDev1:getRxQueue(args.queue_pair), args.size, args.sport, args.dport)
                else
                        mg.startTask("loadSlave", txDev1:getTxQueue(args.queue_pair), rxDev1, args.size, args.sport, args.dport)
		end

		arp.startArpTask{
               		 -- run ARP on both ports
               		 { rxQueue = rxDev1:getRxQueue(args.queue_pair), txQueue = rxDev1:getTxQueue(args.queue_pair), ips = RX_IP },
               		 -- we need an IP address to do ARP requests on this interface
               		 { rxQueue = txDev1:getRxQueue(args.queue_pair), txQueue = txDev1:getTxQueue(args.queue_pair), ips = ARP_IP }
        	}

	end

	mg.waitForTasks()
end

local function fillUdpPacket(buf, len, src_port, dst_port)
	buf:getUdpPacket():fill{
		ethSrc = queue,
		ethDst = DST_MAC,
		ip4Src = SRC_IP,
		ip4Dst = DST_IP,
		udpSrc = src_port,
		udpDst = dst_port,
		pktLength = len
	}
end

local function doArp()
	if not DST_MAC then
		log:info("Performing ARP lookup on %s", GW_IP)
		DST_MAC = arp.blockingLookup(GW_IP, 5)
		if not DST_MAC then
			log:info("ARP lookup failed, using default destination mac address")
			return
		end
	end
	log:info("Destination mac: %s", DST_MAC)
end

function loadSlave(queue, rxDev, size, src_port, dst_port)
	-- interval = time interval or interflow generation gap
	doArp()
	local mempool = memory.createMemPool(function(buf)
		fillUdpPacket(buf, size, src_port, dst_port)
	end)
	local bufs = mempool:bufArray()
	local counter = 0
	local txCtr = stats:newDevTxCounter(queue, "plain")
	local rxCtr = stats:newDevRxCounter(rxDev, "plain")
	local baseIP = parseIPAddress(SRC_IP_BASE)
	while mg.running() do
		bufs:alloc(size)
		for i, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			--pkt.ip4.src:set(baseIP + counter)
			pkt.ip4.src:set(baseIP)
			counter = incAndWrap(counter, flows)
			pkt.udp.src:set(src_port)
			pkt.udp.dst:set(dst_port)
		end
		-- UDP checksums are optional, so using just IPv4 checksums would be sufficient here
		bufs:offloadUdpChecksums()
		queue:send(bufs)
		txCtr:update()
		rxCtr:update()
	end
	txCtr:finalize()
	rxCtr:finalize()
end

function timerSlave(txQueue, rxQueue, size, src_port, dst_port)
	doArp()
	if size < 84 then
		log:warn("Packet size %d is smaller than minimum timestamp size 84. Timestamped packets will be larger than load packets.", size)
		size = 84
	end
	log.info("%d: Packet timestamping is activated.", txQueue)

	local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
	local hist = hist:new()
	mg.sleepMillis(1000) -- ensure that the load task is running
	local counter = 0
	local rateLimit = timer:new(0.001)
	local baseIP = parseIPAddress(SRC_IP_BASE)
	while mg.running() do
		hist:update(timestamper:measureLatency(size, function(buf)
			fillUdpPacket(buf, size, src_port, dst_port)
			local pkt = buf:getUdpPacket()
			--pkt.ip4.src:set(baseIP + counter)
			pkt.ip4.src:set(baseIP + 10) -- SRC IP is chosen for testing purposes (no valid reason)
			counter = incAndWrap(counter, flows)
			pkt.udp.src:set(src_port)
                        pkt.udp.dst:set(dst_port)
		end))
		rateLimit:wait()
		rateLimit:reset()
	end
	-- print the latency stats after all the other stuff
	mg.sleepMillis(300)
	hist:print()
	hist:save("histogram_latency.csv")
end

