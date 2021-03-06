--- Route guide example client.
-- route_guide_client.lua

require("init_package_path")
local grpc = require("grpc_lua.grpc_lua")
local db = require("db")
local inspect = require("inspect")

local SVC = "routeguide.RouteGuide"
local c_channel  -- C `Channel` object
local kCoordFactor = 10000000.0

-- New stub on the same channel.
local function new_stub()
    return grpc.service_stub(c_channel, SVC)
end

local function point(latitude, longitude)
    return { latitude = latitude, longitude = longitude }
end  -- point()

local function rectangle(lo_latitude, lo_longitude,
                         hi_latitude, hi_longitude)
    return { lo = point(lo_latitude, lo_longitude),
             hi = point(hi_latitude, hi_longitude) }
end  -- rectangle()

local function route_note(message, latitude, longitude)
    return { message = message, location = point(latitude, longitude) }
end  -- route_note()

local notes = { route_note("First message", 0, 0),
                route_note("Second message", 0, 1),
                route_note("Third message", 1, 0),
                route_note("Fourth message", 0, 0) }

local function print_route_summary(summary)
    print(string.format(
[[Finished trip with %d points
Passed %d features
Traveled %d meters
It took %d seconds]],
        summary.point_count, summary.feature_count,
        summary.distance, summary.elapsed_time))
end

local function sync_get_feature()
    print("-------------- Sync get feature --------------")
    local stub = new_stub()
    local feature
    feature = stub:sync_request("GetFeature", point(409146138, -746188906))
    print("Found feature: "..inspect(feature))
    feature = stub:sync_request("GetFeature", point(0, 0))
    print("Found feature: "..inspect(feature))
end  -- sync_get_feature()

local function sync_list_features()
    print("-------------- Sync list features --------------")
    local stub = new_stub()
    local rect = rectangle(400000000, -750000000, 420000000, -730000000)
    print("Looking for features between 40, -75 and 42, -73")
    local sync_reader = stub:sync_request_read("ListFeatures", rect)
    -- request_read, request_write, request_rdwr ? XXX
    while true do
        local f = sync_reader:read_one()
        if not f then break end
        print(string.format("Found feature %s at %f,%f", f.name,
            f.location.latitude/kCoordFactor, f.location.longitude/kCoordFactor))
    end  -- while
    -- sync_reader.recv_status() XXX
    print("ListFeatures rpc succeeded.")
    -- print("ListFeatures rpc failed.")
end  -- sync_list_features()

local function sync_record_route()
    print("-------------- Sync record route --------------")
    local stub = new_stub()
    local sync_writer = stub:sync_request_write("RecordRoute")
    for i = 1, 10 do
        local feature = db.get_rand_feature()
        local loc = assert(feature.location)
        print(string.format("Visiting point (%f, %f)",
            loc.latitude/kCoordFactor, loc.longitude/kCoordFactor))
        if not sync_writer:write(loc) then
            print("Failed to sync write.")
            break
        end  -- if
    end  -- for

    -- Recv status and reponse.
    local summary, error_str, status_code = sync_writer:close()  -- Todo: timeout
    if not summary then
        print(string.format("RecordRoute rpc failed: (%d)%s.",
            status_code, error_str))
        return
    end
    print_route_summary(summary)
end  -- sync_record_route()

local function sync_route_chat()
    print("-------------- Sync route chat --------------")
    local stub = new_stub()
    local sync_rdwr = stub:sync_request_rdwr("RouteChat")

    for _, note in ipairs(notes) do
        -- write one then read one
        print("Sending message: " .. inspect(note))
        sync_rdwr:write(note)
    end  -- for
    sync_rdwr:close_writing()

    while true do
        local server_note = sync_rdwr:read_one()
        if not server_note then break end
        print("Got message: "..inspect(server_note))
    end  -- while
end  -- sync_route_chat()

local function get_feature_async()
    print("-------------- Get feature async --------------")
    local stub = new_stub()
    stub:async_request("GetFeature", point())  -- ignore response
    stub:async_request("GetFeature", point(409146138, -746188906),
        function(resp)
            print("Get feature: "..inspect(resp))
            stub:shutdown()  -- to return
        end)
    stub:run()  -- run async requests until stub:shutdown()
end  -- get_feature_async()

local function list_features_async()
    print("-------------- List features async --------------")
    local stub = new_stub()
    local rect = rectangle(400000000, -750000000, 420000000, -730000000)
    print("Looking for features between 40, -75 and 42, -73")
    stub:async_request_read("ListFeatures", rect,
        function(f)
            assert("table" == type(f))
            print(string.format("Found feature %s at %f,%f", f.name,
                f.location.latitude/kCoordFactor, f.location.longitude/kCoordFactor))
        end,
        function(error_str, status_code)
            assert("number" == type(status_code))
            print(string.format("End status: (%d)%s", status_code, error_str))
            stub:shutdown()  -- To break Run().
        end)
    stub:run()  -- until stub:shutdown()
end  -- list_features_async()

local function record_route_async()
    print("-------------- Record route async --------------")
    local stub = new_stub()
    local async_writer = stub:async_request_write("RecordRoute")
    for i = 1, 10 do
        local f = db.get_rand_feature()
        local loc = f.location
        print(string.format("Visiting point %f,%f", 
              loc.latitude/kCoordFactor, loc.longitude/kCoordFactor))
        if not async_writer:write(loc) then break end  -- Broken stream.
    end  -- for

    -- Recv reponse and status.
    async_writer:close(
        function(resp, error_str, status_code)
            if resp then
                assert("table" == type(resp))
                print_route_summary(resp)
            else
                print(string.format("RecordRoute rpc failed. (%d)%s",
                    status_code, error_str))
            end  -- if
            stub:shutdown()  -- to break run()
        end)
    stub:run()  -- until stutdown()
end  -- record_route_async()

local function route_chat_async()
    print("-------------- Route chat async --------------")
    local stub = new_stub()

    local rdwr = stub:async_request_rdwr("RouteChat",
        function(error_str, status_code)
            if error_str then
                print(string.format("RouteChat rpc failed. (%d)%s",
                    status_code, error_str))
            end  -- if
            stub:shutdown()  -- to break run()
        end)

    rdwr:read_each(function(server_note)
        assert("table" == type(server_note))
        print("Got message: "..inspect(server_note))
    end)

    for _, note in ipairs(notes) do
        print("Sending message: " .. inspect(note))
        rdwr:write(note)
    end
    rdwr:close_writing()

    stub:run()  -- until shutdown()
end  -- route_chat_async()

local function main()
    db.load()
    grpc.import_proto_file("route_guide.proto")
    c_channel = grpc.channel("localhost:50051")

    sync_get_feature()
    sync_list_features()
    sync_record_route()
    sync_route_chat()

    get_feature_async()
    list_features_async()
    record_route_async()
    route_chat_async()
end  -- main()

main()
