package db

// This file defines the database schema for our enhanced nugitea system

// User table structure
type User struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Email    string `json:"email"`
	Password string `json:"password"`
	Admin    bool   `json:"admin"`
	Created  int64  `json:"created"`
	Updated  int64  `json:"updated"`
}

// Team table structure  
type Team struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Created int64  `json:"created"`
	Updated int64  `json:"updated"`
}

// TeamMember table (many-to-many relationship between users and teams)
type TeamMember struct {
	TeamID   int64 `json:"team_id"`
	UserID   int64 `json:"user_id"`
	Created  int64 `json:"created"`
}

// Repository table structure
type Repository struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Private     bool   `json:"private"`
	Created     int64  `json:"created"`
	Updated     int64  `json:"updated"`
	OwnerID     int64  `json:"owner_id"`
}

// Issue table structure
type Issue struct {
	ID          int64  `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Status      string `json:"status"` // open, closed
	AssigneeID  *int64 `json:"assignee_id,omitempty"`
	CreatorID   int64  `json:"creator_id"`
	RepoID      int64  `json:"repo_id"`
	Created     int64  `json:"created"`
	Updated     int64  `json:"updated"`
}

// PullRequest table structure
type PullRequest struct {
	ID           int64  `json:"id"`
	Title        string `json:"title"`
	Description  string `json:"description"`
	Status       string `json:"status"` // open, closed, merged
	SourceRepoID int64  `json:"source_repo_id"`
	TargetRepoID int64  `json:"target_repo_id"`
	SourceRef    string `json:"source_ref"`
	TargetRef    string `json:"target_ref"`
	CreatorID    int64  `json:"creator_id"`
	Created      int64  `json:"created"`
	Updated      int64  `json:"updated"`
}

// Migration script to create tables
const CreateTablesSQL = `
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    admin BOOLEAN DEFAULT FALSE,
    created INTEGER NOT NULL,
    updated INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS teams (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    created INTEGER NOT NULL,
    updated INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS team_members (
    team_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    created INTEGER NOT NULL,
    PRIMARY KEY (team_id, user_id)
);

CREATE TABLE IF NOT EXISTS repositories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    private BOOLEAN DEFAULT FALSE,
    created INTEGER NOT NULL,
    updated INTEGER NOT NULL,
    owner_id INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS issues (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    description TEXT,
    status TEXT DEFAULT 'open',
    assignee_id INTEGER,
    creator_id INTEGER NOT NULL,
    repo_id INTEGER NOT NULL,
    created INTEGER NOT NULL,
    updated INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS pull_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    description TEXT,
    status TEXT DEFAULT 'open',
    source_repo_id INTEGER NOT NULL,
    target_repo_id INTEGER NOT NULL,
    source_ref TEXT NOT NULL,
    target_ref TEXT NOT NULL,
    creator_id INTEGER NOT NULL,
    created INTEGER NOT NULL,
    updated INTEGER NOT NULL
);
`