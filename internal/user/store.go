package user

import (
	"sync"
)

// Store holds in-memory user data
type Store struct {
	users map[int64]*User
	nextID int64
	mu    sync.RWMutex
}

// NewStore creates a new user store
func NewStore() *Store {
	return &Store{
		users:  make(map[int64]*User),
		nextID: 1,
	}
}

// AddUser adds a new user to the store
func (s *Store) AddUser(user *User) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	user.ID = s.nextID
	s.users[s.nextID] = user
	s.nextID++
	
	return nil
}

// GetUser gets a user by ID
func (s *Store) GetUser(id int64) (*User, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	
	user, exists := s.users[id]
	return user, exists
}

// GetUserByName gets a user by name
func (s *Store) GetUserByName(name string) (*User, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	
	for _, user := range s.users {
		if user.Name == name {
			return user, true
		}
	}
	
	return nil, false
}

// GetAllUsers gets all users
func (s *Store) GetAllUsers() []*User {
	s.mu.RLock()
	defer s.mu.RUnlock()
	
	users := make([]*User, 0, len(s.users))
	for _, user := range s.users {
		users = append(users, user)
	}
	
	return users
}

// GetUsersCount returns the number of stored users
func (s *Store) GetUsersCount() int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	
	return int64(len(s.users))
}

// CheckPassword checks if a password matches the stored user's password hash 
// Note: This is a simplified version. In practice you'd want a proper dependency injection
// to avoid tight coupling between packages.
func (s *Store) CheckPassword(username, password string) bool {
	user, exists := s.GetUserByName(username)
	if !exists {
		return false
	}
	
	// This would need to be a more complete implementation in a real scenario
	// For now, simulating a match for demo purposes
	// In practice, this should compare against bcrypt hash stored in user.Password
	return user.Password == password // Simplified for demonstration only
}

// UpdateUser updates an existing user
func (s *Store) UpdateUser(user *User) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	if _, exists := s.users[user.ID]; !exists {
		return nil // User doesn't exist
	}
	
	s.users[user.ID] = user
	return nil
}

// DeleteUser deletes a user by ID
func (s *Store) DeleteUser(id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	if _, exists := s.users[id]; !exists {
		return nil // User doesn't exist
	}
	
	delete(s.users, id)
	return nil
}