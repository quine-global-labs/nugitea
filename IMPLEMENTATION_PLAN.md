# Implementation Plan for Enhancing Nugitea to be More Gitea-like

## Overview
This document outlines the implementation plan for adding user management, authentication, web UI, issue tracking, and pull requests to nugitea, bringing it closer to Gitea's functionality.

## Current State
- Basic repository management (clone, push, SSH, HTTP)
- Mock authentication system that allows access to all repositories
- In-memory user storage 
- Simple web handlers for dashboard and users
- No proper password handling or session management

## Implementation Steps

### 1. Password Hashing System (Priority: High)
- Implement secure password hashing using bcrypt or similar library
- Add password validation functions
- Update user model to securely store passwords

### 2. Authentication Enhancements (Priority: High)
- Replace mock authentication with real credential checking
- Implement login/logout endpoints with session management
- Create proper JWT token or cookie-based authentication

### 3. Database Schema Design (Priority: High)
- Design database schema for users, teams, repositories, issues, pull requests
- Create migration scripts for the schema
- Implement data persistence layer

### 4. Complete User Management System (Priority: High)
- Full CRUD operations for users
- Team management functionality 
- User role and permission handling
- Admin panel for user management

### 5. Web UI Enhancement (Priority: Medium)
- Create comprehensive web interface with multiple pages
- Implement repository listing, browsing, and management
- Add issue tracking pages
- Add pull request management pages

### 6. Issue Tracking System (Priority: Medium)
- Implement issue creation, viewing, and management
- Add ability to assign issues to users
- Support for labels, comments, and status updates

### 7. Pull Request System (Priority: Medium)
- Implement pull request creation and review workflow
- Support for code commenting and merge functionality

## Detailed Implementation Plan

### Phase 1: Infrastructure & Authentication (Week 1)
1. Setup proper database schema design
2. Implement password hashing system
3. Enhance authentication with real validation
4. Add session management

### Phase 2: User Management (Week 2)
1. Complete CRUD functionality for users
2. Implement team management
3. Add role-based access control
4. Create user and admin panels

### Phase 3: Web UI Enhancement (Week 3)
1. Build repository browsing interface
2. Implement dashboard with stats
3. Add issue tracking interface
4. Build pull request interface

### Phase 4: Core Features (Week 4)
1. Complete issue tracking system
2. Implement pull request workflow
3. Add webhooks support
4. Implement CI/CD features if time allows

## Technology Stack
- Go for core backend
- PostgreSQL or SQLite for data persistence  
- JWT tokens for authentication
- HTML/CSS/JS for web UI (possibly Bootstrap for styling)

## Files to Create/Modify
1. `/internal/db/schema.go` - Database schema definition
2. `/internal/auth/password.go` - Password hashing and validation
3. `/internal/user/store_db.go` - Database user store implementation
4. `/internal/web/ui/` - Web UI templates and assets
5. `/internal/issues/` - Issue tracking system
6. `/internal/pullrequests/` - Pull request system

## Key Challenges
- Migrating from in-memory storage to persistent storage while maintaining compatibility
- Implementing proper session management
- Maintaining existing Git functionality during enhancements
- Ensuring data security and proper access controls