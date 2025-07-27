const std = @import("std");
const net = std.net;
const http = std.http;
const Random = std.Random;

const TopicData = struct {
    name: []const u8,
    facts: [][]const u8,
    
    fn deinit(self: *TopicData, allocator: std.mem.Allocator) void {
        for (self.facts) |fact| {
            allocator.free(fact);
        }
        allocator.free(self.facts);
        allocator.free(self.name);
    }
};

var topics_data: std.ArrayList(TopicData) = undefined;

fn parseYamlFile(allocator: std.mem.Allocator, file_content: []const u8) ![][]const u8 {
    var facts = std.ArrayList([]const u8).init(allocator);
    defer facts.deinit();
    
    var line_iter = std.mem.tokenizeScalar(u8, file_content, '\n');
    while (line_iter.next()) |line| {
        if (line.len > 2 and line[0] == '-' and line[1] == ' ') {
            const fact = try allocator.dupe(u8, line[2..]);
            try facts.append(fact);
        }
    }
    
    return try facts.toOwnedSlice();
}

fn loadTopicsFromDataDir(allocator: std.mem.Allocator) !void {
    topics_data = std.ArrayList(TopicData).init(allocator);
    
    const data_dir = "src/data";
    var dir = std.fs.cwd().openDir(data_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open data directory: {}\n", .{err});
        return;
    };
    defer dir.close();
    
    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".yaml")) {
            const file_content = try dir.readFileAlloc(allocator, entry.name, 1024 * 1024);
            defer allocator.free(file_content);
            
            const topic_name = try allocator.dupe(u8, entry.name[0..entry.name.len - 5]);
            const facts = try parseYamlFile(allocator, file_content);
            
            try topics_data.append(.{
                .name = topic_name,
                .facts = facts,
            });
        }
    }
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_char, b_char| {
        if (std.ascii.toLower(a_char) != std.ascii.toLower(b_char)) {
            return false;
        }
    }
    return true;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try loadTopicsFromDataDir(allocator);
    defer {
        for (topics_data.items) |*topic| {
            topic.deinit(allocator);
        }
        topics_data.deinit();
    }

    const port: u16 = if (std.process.getEnvVarOwned(allocator, "PORT")) |port_str| blk: {
        defer allocator.free(port_str);
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 8080;
    } else |_| 8080;

    const address = try net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{});
    defer server.deinit();

    std.debug.print("Server listening on http://0.0.0.0:{d}\n", .{port});

    var prng = Random.DefaultPrng.init(@intCast(std.time.timestamp()));

    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();

        var read_buffer: [1024]u8 = undefined;
        var server_conn = http.Server.init(connection, &read_buffer);

        while (server_conn.state == .ready) {
            var request = server_conn.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => break,
                else => return err,
            };

            try handleRequest(&request, allocator, &prng);
        }
    }
}

fn handleRequest(request: *http.Server.Request, allocator: std.mem.Allocator, prng: *Random.DefaultPrng) !void {
    const target = request.head.target;

    if (std.mem.startsWith(u8, target, "/facts")) {
        try handleFacts(request, allocator, prng);
    } else if (std.mem.eql(u8, target, "/topics")) {
        try handleTopics(request, allocator);
    } else {
        try sendJsonResponse(request, .not_found, "{\"error\": \"Not found\"}");
    }
}

fn parseQueryParams(target: []const u8) struct { topic: ?[]const u8, count: ?[]const u8 } {
    var topic: ?[]const u8 = null;
    var count: ?[]const u8 = null;
    
    if (std.mem.indexOf(u8, target, "?")) |q_index| {
        const query_string = target[q_index + 1..];
        var param_iter = std.mem.tokenizeScalar(u8, query_string, '&');
        
        while (param_iter.next()) |param| {
            if (std.mem.indexOf(u8, param, "=")) |eq_index| {
                const key = param[0..eq_index];
                const value = param[eq_index + 1..];
                
                if (std.mem.eql(u8, key, "topic")) {
                    topic = value;
                } else if (std.mem.eql(u8, key, "count")) {
                    count = value;
                }
            }
        }
    }
    
    return .{ .topic = topic, .count = count };
}

fn handleFacts(request: *http.Server.Request, allocator: std.mem.Allocator, prng: *Random.DefaultPrng) !void {
    const params = parseQueryParams(request.head.target);
    
    if (params.count == null) {
        try sendJsonResponse(request, .bad_request, "{\"error\": \"Missing required parameter: count\"}");
        return;
    }
    
    const count = std.fmt.parseInt(usize, params.count.?, 10) catch {
        try sendJsonResponse(request, .bad_request, "{\"error\": \"Invalid count parameter\"}");
        return;
    };
    
    var facts_list = std.ArrayList([]const u8).init(allocator);
    defer facts_list.deinit();
    
    for (topics_data.items) |topic_data| {
        if (params.topic == null or eqlIgnoreCase(topic_data.name, params.topic.?)) {
            for (topic_data.facts) |fact| {
                try facts_list.append(fact);
            }
        }
    }
    
    if (facts_list.items.len == 0) {
        try sendJsonResponse(request, .ok, "[]");
        return;
    }
    
    var selected_facts = std.ArrayList(struct { topic: []const u8, fact: []const u8 }).init(allocator);
    defer selected_facts.deinit();
    
    const actual_count = @min(count, facts_list.items.len);
    var selected_indices = try allocator.alloc(bool, facts_list.items.len);
    defer allocator.free(selected_indices);
    @memset(selected_indices, false);
    
    var i: usize = 0;
    while (i < actual_count) : (i += 1) {
        var idx: usize = undefined;
        while (true) {
            idx = prng.random().intRangeAtMost(usize, 0, facts_list.items.len - 1);
            if (!selected_indices[idx]) {
                selected_indices[idx] = true;
                break;
            }
        }
        
        const fact = facts_list.items[idx];
        var topic_name: []const u8 = "";
        for (topics_data.items) |topic_data| {
            for (topic_data.facts) |tf| {
                if (std.mem.eql(u8, tf, fact)) {
                    topic_name = topic_data.name;
                    break;
                }
            }
        }
        
        try selected_facts.append(.{ .topic = topic_name, .fact = fact });
    }
    
    var json_array = std.ArrayList(u8).init(allocator);
    defer json_array.deinit();
    
    try json_array.appendSlice("[");
    
    for (selected_facts.items, 0..) |item, idx| {
        if (idx > 0) try json_array.appendSlice(",");
        
        try json_array.appendSlice("{\"topic\":\"");
        try json_array.appendSlice(item.topic);
        try json_array.appendSlice("\",\"fact\":\"");
        try json_array.appendSlice(item.fact);
        try json_array.appendSlice("\"}");
    }
    
    try json_array.appendSlice("]");
    
    try sendJsonResponse(request, .ok, json_array.items);
}

fn handleTopics(request: *http.Server.Request, allocator: std.mem.Allocator) !void {
    var json_array = std.ArrayList(u8).init(allocator);
    defer json_array.deinit();
    
    try json_array.appendSlice("[");
    
    for (topics_data.items, 0..) |topic_data, i| {
        if (i > 0) try json_array.appendSlice(",");
        try json_array.appendSlice("\"");
        try json_array.appendSlice(topic_data.name);
        try json_array.appendSlice("\"");
    }
    
    try json_array.appendSlice("]");
    
    try sendJsonResponse(request, .ok, json_array.items);
}

fn sendJsonResponse(request: *http.Server.Request, status: http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "connection", .value = "close" },
        },
    });
}