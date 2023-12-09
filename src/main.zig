const std = @import("std");
const log = std.log;
const mem = std.mem;
const http = std.http;
const net = std.net;
const Allocator = mem.Allocator;

const server_addr = "127.0.0.1";
const server_port = 8000;

const XSServer = struct {
    s: http.Server,
    r: Router,

    pub fn init(alloc: Allocator) XSServer {
        // Initialize the server.
        var server = http.Server.init(alloc, .{ .reuse_address = true });
        defer server.deinit();

        const routes = [_]Router.Route{
            Router.Route{ .method = .GET, .path = "/hey/:name", .handler = heyHandler },
            Router.Route{ .method = .GET, .path = "/florida/:name/ice/:id", .handler = folridaHandler },
            Router.Route{ .method = .GET, .path = "miles", .handler = milesHandler },
        };

        const router = Router{ .routes = &routes };

        return XSServer{ .s = server, .r = router };
    }

    pub fn listenAndServe(self: *XSServer, alloc: Allocator) !void {
        // Parse the server address.
        const address = net.Address.parseIp(server_addr, server_port) catch unreachable;
        try self.s.listen(address);

        // Log the server address and port.
        log.info("Server is running at {s}:{d}", .{ server_addr, server_port });

        outer: while (true) {
            // Accept incoming connection.
            var response = try self.s.accept(.{
                .allocator = alloc,
            });
            defer response.deinit();

            while (response.reset() != .closing) {
                // Handle errors during request processing.
                response.wait() catch |err| switch (err) {
                    error.HttpHeadersInvalid => continue :outer,
                    error.EndOfStream => continue,
                    else => return err,
                };

                try self.r.route(&response, alloc);
            }
        }
    }
};

const Router = struct {
    routes: []const Route,

    const Route = struct {
        method: http.Method,
        path: []const u8,
        handler: Handler,
    };

    const Handler = *const fn (Allocator, *http.Server.Response, [][]const u8, std.HashMap([]const u8, []const u8, std.hash_map.StringContext, 80)) anyerror!void;

    fn route(self: *Router, response: *http.Server.Response, allocator: Allocator) !void {
        // Log the request details.
        log.info("{s} {s} {s}", .{ @tagName(response.request.method), @tagName(response.request.version), response.request.target });

        // Check if the request target contains "?chunked".
        // if (std.mem.indexOf(u8, response.request.target, "?chunked") != null) {
        //     response.transfer_encoding = .chunked;
        // } else {
        //     response.transfer_encoding = .{ .content_length = 10 };
        // }
        var my_hash_map = std.StringHashMap([]const u8).init(allocator);
        defer my_hash_map.deinit();
        var list = std.ArrayList([]const u8).init(allocator);
        defer list.deinit();

        var route_path = std.ArrayList([]const u8).init(allocator);
        var target_path = std.ArrayList([]const u8).init(allocator);

        var tok_itr_target = mem.tokenizeAny(u8, response.request.target, "/");
        while (true) {
            const tmpTargetPathChunk = tok_itr_target.next() orelse "";
            if (mem.eql(u8, tmpTargetPathChunk, "")) {
                break;
            }

            try target_path.append(tmpTargetPathChunk);
        }
        const target_path_owned = try target_path.toOwnedSlice();

        // loop through routes and check if path matches
        var validRoute: bool = false;
        for (self.routes) |r| {
            var tok_itr_route = mem.tokenizeAny(u8, r.path, "/");
            while (true) {
                const tmpRoutePathChunk = tok_itr_route.next() orelse "";
                if (mem.eql(u8, tmpRoutePathChunk, "")) {
                    break;
                }

                try route_path.append(tmpRoutePathChunk);
            }
            const route_path_owned = try route_path.toOwnedSlice();

            std.debug.print("ROUTE_PATH: {any}\n", .{route_path_owned.len});
            std.debug.print("TARGET_PATH: {any}\n", .{target_path_owned.len});

            if (route_path_owned.len == target_path_owned.len) {
                for (route_path_owned, 0..) |routeChunk, i| {
                    if (routeChunk[0] == ':') {
                        try list.append(target_path_owned[i]);
                        try my_hash_map.putNoClobber(routeChunk[1..], target_path_owned[i]);
                        continue;
                    }

                    if (mem.eql(u8, routeChunk, target_path_owned[i])) {
                        validRoute = true;
                    } else {
                        validRoute = false;
                        break;
                    }
                }
            }
            if (validRoute) {
                if (response.request.method == r.method) {
                    const slug = try list.toOwnedSlice();
                    try r.handler(allocator, response, slug, my_hash_map);
                } else {
                    response.status = .method_not_allowed;
                    try response.headers.append("content-type", "text/plain");
                    try response.send();
                    response.transfer_encoding = .{ .content_length = 22 };
                    try response.writeAll("405 method not allowed");
                    try response.finish();
                }
                return;
            }
            // } else {
            //     response.status = .not_found;
            //     try response.headers.append("content-type", "text/plain");
            //     try response.send();
            //     response.transfer_encoding = .{ .content_length = 13 };
            //     try response.writeAll("404 not found");
            //     try response.finish();
            //     break;
            // }
        }
        response.status = .not_found;
        try response.headers.append("content-type", "text/plain");
        try response.send();
        response.transfer_encoding = .{ .content_length = 13 };
        try response.writeAll("404 not found");
        try response.finish();
        // std.debug.print("HASMAP: {any}\n", .{@TypeOf(my_hash_map)});
    }
};

fn heyHandler(alloc: Allocator, response: *http.Server.Response, slug: [][]const u8, hash_map: std.HashMap([]const u8, []const u8, std.hash_map.StringContext, 80)) anyerror!void {
    std.debug.print("TESTINGSSSS: {s}\n\n", .{slug[0]});
    std.debug.print("HASH MAPPPPPPPPPPPPPPPPP: {?s}\n\n", .{hash_map.get("name")});
    const name = slug[0];
    // Read the request body.
    const body = try response.reader().readAllAlloc(alloc, 8192);
    defer alloc.free(body);

    // Set "connection" header to "keep-alive" if present in request headers.
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    const msg = try std.fmt.allocPrint(alloc, "Hey {s}", .{name});
    // Check if the request target contains "?chunked".
    if (std.mem.indexOf(u8, response.request.target, "?chunked") != null) {
        response.transfer_encoding = .chunked;
    } else {
        response.transfer_encoding = .{ .content_length = msg.len };
    }
    // Set "content-type" header to "text/plain".
    try response.headers.append("content-type", "text/plain");

    // Write the response body.
    try response.send();
    try response.writeAll(msg);
    try response.finish();
}

fn folridaHandler(alloc: Allocator, response: *http.Server.Response, slug: [][]const u8, hash_map: std.HashMap([]const u8, []const u8, std.hash_map.StringContext, 80)) anyerror!void {
    _ = hash_map;
    const name = slug[0];
    const id = slug[1];
    std.debug.print("TESTINGSSSS: {s}\n\n", .{name});
    std.debug.print("TESTINGSSSS: {s}\n\n", .{id});
    // Read the request body.
    const body = try response.reader().readAllAlloc(alloc, 8192);
    defer alloc.free(body);

    // Set "connection" header to "keep-alive" if present in request headers.
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    const msg = try std.fmt.allocPrint(alloc, "Hey {s}", .{name});
    // Check if the request target contains "?chunked".
    if (std.mem.indexOf(u8, response.request.target, "?chunked") != null) {
        response.transfer_encoding = .chunked;
    } else {
        response.transfer_encoding = .{ .content_length = msg.len };
    }
    // Set "content-type" header to "text/plain".
    try response.headers.append("content-type", "text/plain");

    // Write the response body.
    try response.send();
    try response.writeAll(msg);
    try response.finish();
}

fn milesHandler(alloc: Allocator, response: *http.Server.Response, slug: [][]const u8, hash_map: std.HashMap([]const u8, []const u8, std.hash_map.StringContext, 80)) anyerror!void {
    _ = slug;
    _ = hash_map;
    // const name = slug[0];
    // const id = slug[1];
    // std.debug.print("TESTINGSSSS: {s}\n\n", .{name});
    // std.debug.print("TESTINGSSSS: {s}\n\n", .{id});
    // Read the request body.
    const body = try response.reader().readAllAlloc(alloc, 8192);
    defer alloc.free(body);

    // Set "connection" header to "keep-alive" if present in request headers.
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    const msg = try std.fmt.allocPrint(alloc, "YOOOOOOOOOOOOOOOOOOO DUDE", .{});
    // Check if the request target contains "?chunked".
    if (std.mem.indexOf(u8, response.request.target, "?chunked") != null) {
        response.transfer_encoding = .chunked;
    } else {
        response.transfer_encoding = .{ .content_length = msg.len };
    }
    // Set "content-type" header to "text/plain".
    try response.headers.append("content-type", "text/plain");

    // Write the response body.
    try response.send();
    try response.writeAll(msg);
    try response.finish();
}

pub fn main() !void {
    // Create an allocator.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var server = XSServer.init(allocator);
    try server.listenAndServe(allocator);

    // const routes = [_]Route{
    //     Route{ .method = "GET", .path = "/hey", .handler = heyHandler },
    //     Route{ .method = "GET", .path = "/hey/:name", .handler = heyHandlerName },
    // };

    // Run the server.
    // runServer(&server, &routes, allocator) catch |err| {
    //     // Handle server errors.
    //     log.err("server error: {}\n", .{err});
    //     if (@errorReturnTrace()) |trace| {
    //         std.debug.dumpStackTrace(trace.*);
    //     }
    //     std.os.exit(1);
    // };
}
