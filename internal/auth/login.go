package auth

import (
	"encoding/json"
	"net/http"
)

// LoginRequest represents a login request
type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// LoginResponse represents a login response
type LoginResponse struct {
	Token string `json:"token"`
	User  *User  `json:"user"`
}

// UserStore interface for user storage operations - this avoids circular imports
type UserStore interface {
	GetUserByName(name string) (*User, bool)
	CheckPassword(username, password string) bool
}

// LoginHandler handles user login
func LoginHandler(userStore UserStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		
		var req LoginRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Invalid request body", http.StatusBadRequest)
			return
		}
		
		// Validate credentials against stored users
		if !userStore.CheckPassword(req.Username, req.Password) {
			http.Error(w, "Invalid credentials", http.StatusUnauthorized)
			return
		}
		
		// Get the actual user
		user, exists := userStore.GetUserByName(req.Username)
		if !exists {
			http.Error(w, "User not found", http.StatusUnauthorized)
			return
		}
		
		resp := LoginResponse{
			Token: "mock-jwt-token-for-demo",
			User:  user,
		}
		
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	}
}

// LogoutHandler handles user logout
func LogoutHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		
		// Clear session/cookie in a real implementation
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("Logged out successfully"))
	}
}