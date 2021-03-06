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
local DST_MAC = nil -- temporary placeholder for a resolved MAC
local DST_MAC_NIC1	= nil -- resolved via ARP on GW_IP or DST_IP, can be overriden with a string here
local SRC_IP_BASE_NIC1	= "10.0.0.10" -- source IP address tp use
local DST_IP_NIC1	= "10.1.0.10"

local DST_MAC_NIC2      = nil -- resolved via ARP on GW_IP or DST_IP, can be overriden with a string here
local SRC_IP_BASE_NIC2  = "11.0.0.10" -- actual address will be SRC_IP_BASE + random(0, flows)
local DST_IP_NIC2       = "11.1.0.10"

local SRC_PORT		= 1234
local DST_PORT		= 319
local MAX_QUEUE_COUNT_PORT_82599ES 	= 64
-- answer ARP requests for this IP on the rx port
-- change this if benchmarking something like a NAT device
local RX_IP		= nil
-- used to resolve DST_MAC
local GW_IP		= nil
-- used as source IP to resolve GW_IP to DST_MAC
local ARP_IP	= nil

-- Global variables to track the UDP port numbers (SRC and DST ports)
local SRC_PORT_GLOBAL = 1
local DST_PORT_GLOBAL = 1

--local QUEUE_PAIRS = nil

function configure(parser)
	parser:description("Generates UDP traffic and measure latencies. Edit the source to modify constants like IPs.")
	parser:argument("txDev0", "Device to transmit from (port 1)."):convert(tonumber)
	parser:argument("rxDev0", "Device to receive from (port 2)."):convert(tonumber)
	parser:argument("txDev1", "Device to transmit from (port 3)."):convert(tonumber)
        parser:argument("rxDev1", "Device to receive from (port 4)."):convert(tonumber)
	parser:option("-r --rate", "Transm4it rate in Mbit/s."):default(0):convert(tonumber)
	parser:option("--rate_pps", "Transmit rate in PPS."):default(0):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("--sport", "UDP source port number."):default(SRC_PORT):convert(tonumber)
	parser:option("--dport", "UDP destination port number."):default(DST_PORT):convert(tonumber)
	parser:option("--queue_pairs", "A queue pair number (TX/RX) to use on a NIC's port."):default(0):convert(tonumber)
	parser:option("--tstamp", "Enable(true=0)/Disable(false=1) packet hardware (NIC) timestamping"):default(1):convert(tonumber)
	parser:option("-f --flows", "The number of flows per PACKET RATE GROUP"):default(1):convert(tonumber)

end

function rate_to_Mbps(rate, pk_size)
	local rate_mbps = 0.0

	rate_mbps = rate * (pk_size + 4) * 8 / 10^6

	if rate_mbps > 0.0 then
		return rate_mbps
	else
		log:info("Rate conversion (PPS -> Mbps) failed !!!")
		return 0
	end
end
 
function master(args)
	txDev0 = device.config{port = args.txDev0, rxQueues = 64, txQueues = 64}
	rxDev0 = device.config{port = args.rxDev0, rxQueues = 64, txQueues = 64}
	txDev1 = device.config{port = args.txDev1, rxQueues = 64, txQueues = 64}
        rxDev1 = device.config{port = args.rxDev1, rxQueues = 64, txQueues = 64}
	start_src_port = args.sport
	start_dst_port = args.dport
	--queue_count = 0

	log:info("Parsed argument: TxDev0=%d", args.txDev0)
	log:info("Parsed argument: RxDev0=%d", args.rxDev0)
	log:info("Parsed argument: TxDev1=%d", args.txDev1)
	log:info("Parsed argument: RxDev1=%d", args.rxDev1)
	log:info("Parsed argument: rate=%d Mbps", args.rate)
	log:info("Parsed argument: rate_pps=%d", args.rate_pps)
	log:info("Parsed argument: size=%d", args.size)
	log:info("Parsed argument: sport=%d", args.sport)
	log:info("Parsed argument: dport=%d", args.dport)
	log:info("Parsed argument: queue_pairs=%d", args.queue_pairs)
	log:info("Parsed argument: tstamp=%d", args.tstamp)	
	log:info("Parsed argument: flows per rate group=%d", args.flows)

	device.waitForLinks()
	-- max 1kpps timestamping traffic timestamping
	-- rate will be somewhat off for high-latency links at low rates

	-- Perform ARP resolution procedure before traffic generation routines
	
	if args.queue_pairs <= MAX_QUEUE_COUNT_PORT_82599ES then
		RX_IP = DST_IP_NIC1
		ARP_IP = SRC_IP_BASE_NIC1
		arp.startArpTask{
                	-- run ARP on both ports
                	{ rxQueue = rxDev0:getRxQueue(0), txQueue = rxDev0:getTxQueue(0), ips = RX_IP },
               		-- we need an IP address to do ARP requests on this interface
               		{ rxQueue = txDev0:getRxQueue(0), txQueue = txDev0:getTxQueue(0), ips = ARP_IP }
             	}
	elseif args.queue_pairs > 0 and args.queue_pairs > MAX_QUEUE_COUNT_PORT_82599ES and args.queue_pairs < 2*MAX_QUEUE_COUNT_PORT_82599ES then
		RX_IP = DST_IP_NIC1
                ARP_IP = SRC_IP_BASE_NIC1
		arp.startArpTask{
                        -- run ARP on both ports
                        { rxQueue = rxDev0:getRxQueue(0), txQueue = rxDev0:getTxQueue(0), ips = RX_IP },
                        -- we need an IP address to do ARP requests on this interface
                        { rxQueue = txDev0:getRxQueue(0), txQueue = txDev0:getTxQueue(0), ips = ARP_IP }
                }
		
		RX_IP = DST_IP_NIC2
		ARP_IP = SRC_IP_BASE_NIC2 
		arp.startArpTask{
                	-- run ARP on both ports
                	{ rxQueue = rxDev1:getRxQueue(0), txQueue = rxDev1:getTxQueue(0), ips = RX_IP },
                	-- we need an IP address to do ARP requests on this interface
                	{ rxQueue = txDev1:getRxQueue(0), txQueue = txDev1:getTxQueue(0), ips = ARP_IP }
           	}
	else
		log:info(" Error !!! Wrong number [%d] of rate groups - port queues to use. Max allowed: [%d]", args.queue_pairs, MAX_QUEUE_COUNT_PORT_82599ES)
	end 


	local src_port = args.sport
	local dst_port = args.dport
	local pk_size = 0
	for queue_pair=1,args.queue_pairs do  
		if queue_pair <= MAX_QUEUE_COUNT_PORT_82599ES - 1 then   
			if args.rate > 0 then
				--txDev0:getTxQueue(args.queue_pair):setRate(args.rate - (args.size + 4) * 8 / 1000)
				txDev0:getTxQueue(queue_pair):setRate(args.rate)
				if args.tstamp == 0 then
                                	pk_size = args.size + 24
				else
                                	pk_size = args.size
				end
			elseif args.rate_pps > 0 then -- Note that the minumum resulting rate in Mbps must be >= 10Mbps to ensure accurate 
					      	      -- packet generation in PPS
				--local pk_size = 0
				if args.tstamp == 0 then
					pk_size = args.size + 24
					--txDev0:getTxQueue(args.queue_pair):setRate(rate_to_Mbps(args.rate_pps, pk_size) - (args.size + 4) * 8 / 1000)
					local test_rate = rate_to_Mbps(args.rate_pps, pk_size)
					log:info("Rate in Mbps is: %f", test_rate)
					txDev0:getTxQueue(queue_pair):setRate(rate_to_Mbps(args.rate_pps, pk_size))
				else
					pk_size = args.size
					local test_rate = rate_to_Mbps(args.rate_pps, pk_size)
                                	log:info("Rate in Mbps is: %f", test_rate)

					--txDev0:getTxQueue(args.queue_pair):setRate(rate_to_Mbps(args.rate_pps, pk_size) - (args.size + 4) * 8 / 1000)
                        		txDev0:getTxQueue(queue_pair):setRate(rate_to_Mbps(args.rate_pps, pk_size))
				end
			else
				log:info("TxDev0: Flow rate is not specified!!!. Terminating... ")
				return
			end
		
			if args.tstamp == 0  then
				--mg.startTask("timerSlave", txDev0:getTxQueue(queue_pair), rxDev0:getRxQueue(queue_pair), queue_pair, args.size, src_port, dst_port, args.flows)
			else
				mg.startTask("loadSlave", txDev0:getTxQueue(queue_pair), rxDev0:getRxQueue(queue_pair), queue_pair, args.size, src_port, dst_port, args.flows)
			end
			--[[	
			arp.startArpTask{
               			 -- run ARP on both ports
               			 { rxQueue = rxDev0:getRxQueue(0), txQueue = rxDev0:getTxQueue(0), ips = RX_IP },
               			 -- we need an IP address to do ARP requests on this interface
               			 { rxQueue = txDev0:getRxQueue(0), txQueue = txDev0:getTxQueue(0), ips = ARP_IP }
        		}
			]]
			src_port = src_port + 1
			dst_port = dst_port + 1

		elseif args.queue_pair > MAX_QUEUE_COUNT_PORT_82599ES - 1 then
			if args.rate > 0 then
                        	txDev1:getTxQueue(queue_pair):setRate(args.rate - (args.size + 4) * 8 / 1000)
                	elseif args.rate_pps > 0 then
                        	txDev1:getTxqueue(queue_pair):setRate(rate_to_Mbps(args.rate_pps, args.size) - (args.size + 4) * 8 / 1000)
                	else
                        	log:info("TxDev1: Flow rate is not specified!!!. Terminating... ")
                        	return
                	end

			if args.tstamp then
                        	--mg.startTask("timerSlave", txDev1:getTxQueue(queue_pair), rxDev1:getRxQueue(queue_pair), queue_pair, args.size, src_port, dst_port, args.flows)
                	else
                        	mg.startTask("loadSlave", txDev1:getTxQueue(queue_pair), rxDev1:getRxQueue(queue_pair), queue_pair, args.size, src_port, dst_port, args.flows)
			end
			--[[
			arp.startArpTask{
               			 -- run ARP on both ports
               		 	 { rxQueue = rxDev1:getRxQueue(queue_pair), txQueue = rxDev1:getTxQueue(queue_pair), ips = RX_IP },
               			 -- we need an IP address to do ARP requests on this interface
               			 { rxQueue = txDev1:getRxQueue(queue_pair), txQueue = txDev1:getTxQueue(queue_pair), ips = ARP_IP }
        		}
			]]
			src_port = src_port + 1
                        dst_port = dst_port + 1

		end

		--else
			--log:info("The number of active queues exceeds the capacity of PORT[0, 1]. Configure NIC2!!!.")
		--end
		mg.sleepMillis(20) -- introduce a small delay between the rate groups (each using a dedicated Tx/Rx queue pair. 
	end
	mg.waitForTasks()
end

local function fillUdpPacket_nic1(queue, buf, len, src_port, dst_port)
	buf:getUdpPacket():fill{
		ethSrc = queue,
		ethDst = DST_MAC_NIC1,
		ip4Src = SRC_IP_NIC1,
		ip4Dst = DST_IP_NIC1,
		udpSrc = src_port,
		udpDst = dst_port,
		pktLength = len
	}
end

local function fillUdpPacket_nic2(queue, buf, len, src_port, dst_port)
        buf:getUdpPacket():fill{
                ethSrc = queue,
                ethDst = DST_MAC_NIC2,
                ip4Src = SRC_IP_NIC2,
                ip4Dst = DST_IP_NIC2,
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

function loadSlave(txQueue, rxQueue, queue_nr, size, src_port, dst_port, flows)
	-- comment
	local mempool = nil
	if queue_nr <= MAX_QUEUE_COUNT_PORT_82599ES then
		--log:info("queue number = %d", queue_nr)
		DST_MAC = nil
		GW_IP = DST_IP_NIC1 
		doArp()
		DST_MAC_NIC1 = DST_MAC
		
		local mempool_temp = memory.createMemPool(function(buf)
                	fillUdpPacket_nic1(txQueue, buf, size, src_port, dst_port)
		end)
		mempool = mempool_temp
	else
		DST_MAC = nil
		GW_IP = DST_IP_NIC2
                doArp()
                DST_MAC_NIC2 = DST_MAC
		
		local mempool_temp = memory.createMemPool(function(buf)
                        fillUdpPacket_nic2(txQueue, buf, size, src_port, dst_port)
                end)
		mempool = mempool_temp

	end 

	--local mempool = memory.createMemPool(function(buf)
		--fillUdpPacket(txQueue, buf, size, src_port, dst_port)
	--end)
	local bufs = mempool:bufArray()
	local counter = 0
	local txCtr = stats:newDevTxCounter(txQueue, "plain")
	local rxCtr = stats:newDevRxCounter(rxQueue, "plain")
	--local baseIP = parseIPAddress(SRC_IP_BASE)
	--log:info("The number of flows to generate: [%d]", flows)
	while mg.running() do
		bufs:alloc(size)
		for i, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			--pkt.eth.ethSrc:set(txQueue)
			--pkt.ip4.src:set(baseIP + counter)
			--pkt.ip4.src:set(baseIP)
			--counter = incAndWrap(counter, flows)
			--pkt.udp.src:set(src_port + counter)
			--pkt.udp.dst:set(dst_port + counter)
			--pkt:fill{
				--udpSrc = src_port + counter,
				--udpDst = dst_port + counter,
			--}
			--counter = incAndWrap(counter, flows)

		end
		-- UDP checksums are optional, so using just IPv4 checksums would be sufficient here
		bufs:offloadUdpChecksums()
		txQueue:send(bufs)
		txCtr:update()
		rxCtr:update()
	end
	txCtr:finalize()
	rxCtr:finalize()
end

function timerSlave(txQueue, rxQueue, queue_nr, size, src_port, dst_port, flows)
	--doArp()

	if queue_nr <= MAX_QUEUE_COUNT_PORT_82599ES then
                DST_MAC = nil
                GW_IP = DST_IP_NIC1
                doArp()
                DST_MAC_NIC1 = DST_MAC
        else
                DST_MAC = nil
                GW_IP = DST_IP_NIC2
                doArp()
                DST_MAC_NIC2 = DST_MAC
        end

	if size < 84 then
		log:warn("Packet size %d is smaller than minimum timestamp size 84. Timestamped packets will be larger than load packets.", size)
		size = 84
	end
	--log.info("Packet timestamping is activated.")
	--log.info(txQueue)

	local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
	local hist = hist:new()
	mg.sleepMillis(1000) -- ensure that the load task is running
	local counter = 0
	local rateLimit = timer:new(0.001)
	--local baseIP = parseIPAddress(SRC_IP_BASE)

	if queue_nr <= MAX_QUEUE_COUNT_PORT_82599ES then

		while mg.running() do
			hist:update(timestamper:measureLatency(size, function(buf)
 				fillUdpPacket_nic1(txQueue, buf, size, src_port, dst_port)
				local pkt = buf:getUdpPacket()
				--pkt.eth.ethSrc:set(txQueue)
				--pkt.ip4.src:set(baseIP + counter)
				--pkt.ip4.src:set(baseIP + 10) -- SRC IP is chosen for testing purposes (no valid reason)
				--counter = incAndWrap(counter, flows)
				--pkt.udp.src:set(src_port + counter)
                        	--pkt.udp.dst:set(dst_port + counter)
				--[[pkt:fill{
					pktLength = size,					
					ethSrc = txQueue,
               				ethDst = DST_MAC_NIC1,
                			ip4Src = SRC_IP_NIC1,
                			ip4Dst = DST_IP_NIC1,
                                	udpSrc = src_port + counter,
                                	udpDst = dst_port + counter,
                        	}
				]]

				--counter = incAndWrap(counter, flows)

			end))
			rateLimit:wait()
			rateLimit:reset()
		end
	else
		while mg.running() do
                        hist:update(timestamper:measureLatency(size, function(buf)
				fillUdpPacket_nic2(txQueue, buf, size, src_port, dst_port)
                                local pkt = buf:getUdpPacket()
                                --pkt.eth.ethSrc:set(txQueue)
                                --pkt.ip4.src:set(baseIP + counter)
                                --pkt.ip4.src:set(baseIP + 10) -- SRC IP is chosen for testing purposes (no valid reason)
                                --counter = incAndWrap(counter, flows)
                                --pkt.udp.src:set(src_port)
                                --pkt.udp.dst:set(dst_port)
				pkt:fill{
                                        udpSrc = src_port + counter,
                                        udpDst = dst_port + counter,
                                }
				counter = incAndWrap(counter, flows)

                        end))
                        --rateLimit:wait()
                        --rateLimit:reset()
                end
	end
	-- print the latency stats after all the other stuff
	mg.sleepMillis(300)
	hist:print()
	hist:save("histogram_latency.csv")
end

