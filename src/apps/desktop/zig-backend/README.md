# Desktop Backend - Zig HTTP Server

A simple REST API backend for the desktop application, built in Zig using httpz.

## Building

```bash
cd src/apps/desktop/zig-backend
zig build
```

## Running

```bash
./zig-out/bin/desktop-backend
# Or with custom port:
./zig-out/bin/desktop-backend --port 3000
```

## API Endpoints

### System Folder

- `GET /api/system/folder` - Get current working directory info
- `GET /api/system/folder/list?path=<path>` - List contents of specific directory

Response format:
```json
{
  "path": "dirname",
  "absolute": "/full/path/to/dir",
  "home": "/home/user",
  "parent": "/full/path/to/parent",
  "entries": [
    {
      "name": "filename",
      "path": "/full/path/to/filename",
      "is_directory": true,
      "is_symlink": false
    }
  ]
}
```

### Workspaces

- `GET /api/workspaces` - List all workspaces
- `POST /api/workspaces` - Create a new workspace
- `GET /api/workspaces/{id}` - Get workspace by ID
- `DELETE /api/workspaces/{id}` - Delete a workspace

### Tasks

- `GET /api/workspaces/{workspace_id}/items/{item_id}/tasks` - List tasks
- `POST /api/workspaces/{workspace_id}/items/{item_id}/tasks` - Create task
- `PUT /api/workspaces/{workspace_id}/items/{item_id}/tasks/{task_id}` - Update task
- `DELETE /api/workspaces/{workspace_id}/items/{item_id}/tasks/{task_id}` - Delete task

### Chat (Placeholder)

- `POST /api/chat` - Send chat message (returns placeholder response)
- `GET /api/chat/history/{session_id}` - Get chat history

### Health Check

- `GET /health` - Returns server status

## Architecture

- Uses `httpz` library for HTTP server
- Handler functions receive `AppContext` (allocator, workspaces dir)
- JSON responses are built using `std.fmt.allocPrint` with ctx.allocator
- Directory listing uses `std.fs.openDirAbsolute` with iteration

## Future Improvements

1. Add persistent storage for workspaces/tasks (SQLite)
2. Add AI integration for chat functionality
3. Proper JSON escaping for special characters
4. Error handling improvements
5. CORS support for web clients
6. WebSocket support for real-time updates