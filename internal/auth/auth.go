package auth

import (
	"context"
	"net/http"
)

// User represents a logged-in user
type User struct {
	ID    int64
	Name  string
	Email string
	Admin bool
}

// Context key for user
type contextKey string

const userContextKey contextKey = "user"

// AuthenticateFunc checks if a user is authenticated
type AuthenticateFunc func(r *http.Request) (*User, error)

// RequireAuth middleware that ensures user is authenticated
func RequireAuth(authFunc AuthenticateFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user, err := authFunc(r)
		if err != nil || user == nil {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		
		ctx := context.WithValue(r.Context(), userContextKey, user)
		r = r.WithContext(ctx)
	}
}

// GetUserFromContext retrieves the authenticated user from context
func GetUserFromContext(ctx context.Context) *User {
	user, ok := ctx.Value(userContextKey).(*User)
	if !ok {
		return nil
	}
	return user
}

// MockAuthenticate is a simple mock authentication function for testing
func MockAuthenticate(r *http.Request) (*User, error) {
	// In a real implementation, this would validate credentials
	// For now, we're just checking if basic headers are present for demo purposes
	
	// Return a default admin user for demonstration
	return &User{
		ID:    1,
		Name:  "admin",
		Email: "admin@example.com",
		Admin: true,
	}, nil
}

// AuthenticateUser validates user credentials against the database/user store
func AuthenticateUser(userStore *UserStore, username, password string) (*User, error) {
	user, exists := userStore.GetUserByName(username)
	if !exists {
		return nil, nil // User not found
	}
	
	// Check password using bcrypt
	if !CheckPassword(password, user.Password) {
		return nil, nil // Password incorrect
	}
	
	return user, nil
}