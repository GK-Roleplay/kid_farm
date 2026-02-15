DB = {}

local function awaitResult(invoker)
    local p = promise.new()
    invoker(function(result)
        p:resolve(result)
    end)
    return Citizen.Await(p)
end

function DB.ready(cb)
    MySQL.ready(cb)
end

function DB.fetchAll(query, params)
    return awaitResult(function(done)
        MySQL.Async.fetchAll(query, params or {}, function(rows)
            done(rows or {})
        end)
    end)
end

function DB.fetchOne(query, params)
    local rows = DB.fetchAll(query, params)
    return rows and rows[1] or nil
end

function DB.execute(query, params)
    return awaitResult(function(done)
        MySQL.Async.execute(query, params or {}, function(affectedRows)
            done(affectedRows or 0)
        end)
    end)
end

function DB.scalar(query, params)
    return awaitResult(function(done)
        MySQL.Async.fetchScalar(query, params or {}, function(value)
            done(value)
        end)
    end)
end