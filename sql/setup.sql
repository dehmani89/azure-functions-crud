-- Create the database only if it doesn't already exist.
-- Postgres has no CREATE DATABASE IF NOT EXISTS, so we use psql's \gexec: the
-- SELECT emits the CREATE statement only when the guard finds no matching row,
-- and \gexec then executes whatever the SELECT returned (nothing if it exists).
-- Safe to re-run, and works whether you point psql at 'postgres' or at an
-- already-created 'productsDB'.
SELECT 'CREATE DATABASE "productsDB"'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'productsDB')\gexec

-- Connect to the productsDB database (psql meta-command)
\c "productsDB"

-- Create the products table
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    price NUMERIC(10, 2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Sample INSERT
INSERT INTO products (name, description, price) VALUES
('Dental Chair', 'Ergonomic patient chair with adjustable positioning', 2500.00),
('X-Ray Machine', 'Digital panoramic X-ray system for dental imaging', 15000.00),
('Dental Drill', 'High-speed electric dental handpiece', 800.00),
('Ultrasonic Scaler', 'Piezoelectric scaler for dental cleaning', 450.00),
('LED Curing Light', 'Cordless LED light for composite curing', 350.00),
('Dental Mirror', 'Stainless steel mouth mirror set', 25.00),
('Explorer Probe', 'Double-ended dental explorer and probe', 15.00),
('Forceps Set', 'Complete set of dental extraction forceps', 200.00),
('Amalgam Separator', 'Device for amalgam waste collection', 1200.00),
('Sterilization Unit', 'Autoclave for instrument sterilization', 1800.00),
('Dental Compressor', 'Oil-free air compressor for dental tools', 900.00),
('Suction Unit', 'High-volume evacuator and saliva ejector system', 400.00),
('Intraoral Camera', 'Wireless intraoral camera for patient education', 600.00),
('Dental Light', 'LED operating light for dental procedures', 750.00),
('Patient Monitor', 'Vital signs monitor for dental sedation', 2200.00);

-- Sample SELECT all
SELECT * FROM products;

-- Sample SELECT by ID
SELECT * FROM products WHERE id = 1;

-- Sample UPDATE
UPDATE products SET name = 'Dental Chair 1', updated_at = CURRENT_TIMESTAMP WHERE id = 1;

-- Sample Create for the 16th record
INSERT INTO products (name, description, price) VALUES
    ('Dental Chair 2', 'Ergonomic patient chair with adjustable positioning', 1500.00);

-- Sample DELETE for the 16th record
DELETE FROM products WHERE id = 16;