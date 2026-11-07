export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      admin_audit_logs: {
        Row: {
          action: string
          actor_user_id: string | null
          after_data: Json | null
          before_data: Json | null
          created_at: string
          id: number
          request_id: string | null
          target_id: string | null
          target_table: string
        }
        Insert: {
          action: string
          actor_user_id?: string | null
          after_data?: Json | null
          before_data?: Json | null
          created_at?: string
          id?: never
          request_id?: string | null
          target_id?: string | null
          target_table: string
        }
        Update: {
          action?: string
          actor_user_id?: string | null
          after_data?: Json | null
          before_data?: Json | null
          created_at?: string
          id?: never
          request_id?: string | null
          target_id?: string | null
          target_table?: string
        }
        Relationships: []
      }
      driver_documents: {
        Row: {
          created_at: string
          document_number_last4: string | null
          document_type: string
          driver_id: string
          expires_at: string | null
          id: string
          issued_at: string | null
          object_path: string
          review_note: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          storage_bucket: string
          updated_at: string
          verification_status: string
        }
        Insert: {
          created_at?: string
          document_number_last4?: string | null
          document_type: string
          driver_id: string
          expires_at?: string | null
          id?: string
          issued_at?: string | null
          object_path: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          storage_bucket?: string
          updated_at?: string
          verification_status?: string
        }
        Update: {
          created_at?: string
          document_number_last4?: string | null
          document_type?: string
          driver_id?: string
          expires_at?: string | null
          id?: string
          issued_at?: string | null
          object_path?: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          storage_bucket?: string
          updated_at?: string
          verification_status?: string
        }
        Relationships: []
      }
      driver_locations: {
        Row: {
          accuracy_m: number | null
          driver_id: string
          geohash_7: string | null
          heading_degrees: number | null
          location: unknown
          recorded_at: string
          speed_mps: number | null
          updated_at: string
        }
        Insert: {
          accuracy_m?: number | null
          driver_id: string
          geohash_7?: string | null
          heading_degrees?: number | null
          location: unknown
          recorded_at?: string
          speed_mps?: number | null
          updated_at?: string
        }
        Update: {
          accuracy_m?: number | null
          driver_id?: string
          geohash_7?: string | null
          heading_degrees?: number | null
          location?: unknown
          recorded_at?: string
          speed_mps?: number | null
          updated_at?: string
        }
        Relationships: []
      }
      driver_profiles: {
        Row: {
          active_pincode_id: number | null
          availability_status: string
          created_at: string
          updated_at: string
          user_id: string
          vehicle_category_id: number | null
          vehicle_color: string | null
          vehicle_make: string | null
          vehicle_model: string | null
          vehicle_registration: string | null
          verification_status: string
        }
        Insert: {
          active_pincode_id?: number | null
          availability_status?: string
          created_at?: string
          updated_at?: string
          user_id: string
          vehicle_category_id?: number | null
          vehicle_color?: string | null
          vehicle_make?: string | null
          vehicle_model?: string | null
          vehicle_registration?: string | null
          verification_status?: string
        }
        Update: {
          active_pincode_id?: number | null
          availability_status?: string
          created_at?: string
          updated_at?: string
          user_id?: string
          vehicle_category_id?: number | null
          vehicle_color?: string | null
          vehicle_make?: string | null
          vehicle_model?: string | null
          vehicle_registration?: string | null
          verification_status?: string
        }
        Relationships: [
          {
            foreignKeyName: "driver_profiles_active_pincode_id_fkey"
            columns: ["active_pincode_id"]
            isOneToOne: false
            referencedRelation: "service_area_pincodes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "driver_profiles_vehicle_category_id_fkey"
            columns: ["vehicle_category_id"]
            isOneToOne: false
            referencedRelation: "vehicle_categories"
            referencedColumns: ["id"]
          },
        ]
      }
      driver_service_pincodes: {
        Row: {
          driver_id: string
          id: string
          is_primary: boolean
          pincode_id: number
          requested_at: string
          review_note: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: string
        }
        Insert: {
          driver_id: string
          id?: string
          is_primary?: boolean
          pincode_id: number
          requested_at?: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
        }
        Update: {
          driver_id?: string
          id?: string
          is_primary?: boolean
          pincode_id?: number
          requested_at?: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "driver_service_pincodes_pincode_id_fkey"
            columns: ["pincode_id"]
            isOneToOne: false
            referencedRelation: "service_area_pincodes"
            referencedColumns: ["id"]
          },
        ]
      }
      driver_subscriptions: {
        Row: {
          amount: number
          commercial_config_id: string
          created_at: string
          currency: string
          driver_id: string
          id: string
          payment_record_id: string | null
          period_end: string
          period_start: string
          pincode_id: number
          status: string
          updated_at: string
        }
        Insert: {
          amount: number
          commercial_config_id: string
          created_at?: string
          currency?: string
          driver_id: string
          id?: string
          payment_record_id?: string | null
          period_end: string
          period_start: string
          pincode_id: number
          status?: string
          updated_at?: string
        }
        Update: {
          amount?: number
          commercial_config_id?: string
          created_at?: string
          currency?: string
          driver_id?: string
          id?: string
          payment_record_id?: string | null
          period_end?: string
          period_start?: string
          pincode_id?: number
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "driver_subscriptions_commercial_config_id_fkey"
            columns: ["commercial_config_id"]
            isOneToOne: false
            referencedRelation: "service_area_commercial_configs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "driver_subscriptions_pincode_id_fkey"
            columns: ["pincode_id"]
            isOneToOne: false
            referencedRelation: "service_area_pincodes"
            referencedColumns: ["id"]
          },
        ]
      }
      fare_configs: {
        Row: {
          base_fare: number
          booking_fee: number
          created_at: string
          currency: string
          id: number
          is_active: boolean
          minimum_fare: number
          multiplier: number
          per_km_rate: number
          per_minute_rate: number
          service_area_id: number
          valid_from: string
          valid_until: string | null
          vehicle_category_id: number
        }
        Insert: {
          base_fare: number
          booking_fee?: number
          created_at?: string
          currency?: string
          id?: never
          is_active?: boolean
          minimum_fare: number
          multiplier?: number
          per_km_rate: number
          per_minute_rate?: number
          service_area_id: number
          valid_from?: string
          valid_until?: string | null
          vehicle_category_id: number
        }
        Update: {
          base_fare?: number
          booking_fee?: number
          created_at?: string
          currency?: string
          id?: never
          is_active?: boolean
          minimum_fare?: number
          multiplier?: number
          per_km_rate?: number
          per_minute_rate?: number
          service_area_id?: number
          valid_from?: string
          valid_until?: string | null
          vehicle_category_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "fare_configs_service_area_id_fkey"
            columns: ["service_area_id"]
            isOneToOne: false
            referencedRelation: "service_areas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fare_configs_vehicle_category_id_fkey"
            columns: ["vehicle_category_id"]
            isOneToOne: false
            referencedRelation: "vehicle_categories"
            referencedColumns: ["id"]
          },
        ]
      }
      ledger_entries: {
        Row: {
          amount: number
          created_at: string
          currency: string
          description: string | null
          direction: string
          entry_type: string
          id: string
          idempotency_key: string
          metadata: Json
          owner_user_id: string
          payment_record_id: string | null
          ride_id: string | null
          status: string
        }
        Insert: {
          amount: number
          created_at?: string
          currency?: string
          description?: string | null
          direction: string
          entry_type: string
          id?: string
          idempotency_key: string
          metadata?: Json
          owner_user_id: string
          payment_record_id?: string | null
          ride_id?: string | null
          status?: string
        }
        Update: {
          amount?: number
          created_at?: string
          currency?: string
          description?: string | null
          direction?: string
          entry_type?: string
          id?: string
          idempotency_key?: string
          metadata?: Json
          owner_user_id?: string
          payment_record_id?: string | null
          ride_id?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "ledger_entries_payment_record_id_fkey"
            columns: ["payment_record_id"]
            isOneToOne: false
            referencedRelation: "payment_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ledger_entries_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_records: {
        Row: {
          amount: number
          captured_at: string | null
          created_at: string
          currency: string
          driver_subscription_id: string | null
          id: string
          idempotency_key: string
          metadata: Json
          payee_user_id: string | null
          payer_user_id: string | null
          payment_method: string
          payment_purpose: string
          provider: string | null
          provider_reference: string | null
          refunded_amount: number
          ride_id: string | null
          status: string
          updated_at: string
        }
        Insert: {
          amount: number
          captured_at?: string | null
          created_at?: string
          currency?: string
          driver_subscription_id?: string | null
          id?: string
          idempotency_key: string
          metadata?: Json
          payee_user_id?: string | null
          payer_user_id?: string | null
          payment_method: string
          payment_purpose: string
          provider?: string | null
          provider_reference?: string | null
          refunded_amount?: number
          ride_id?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          amount?: number
          captured_at?: string | null
          created_at?: string
          currency?: string
          driver_subscription_id?: string | null
          id?: string
          idempotency_key?: string
          metadata?: Json
          payee_user_id?: string | null
          payer_user_id?: string | null
          payment_method?: string
          payment_purpose?: string
          provider?: string | null
          provider_reference?: string | null
          refunded_amount?: number
          ride_id?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payment_records_driver_subscription_id_fkey"
            columns: ["driver_subscription_id"]
            isOneToOne: false
            referencedRelation: "driver_subscriptions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_records_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          account_status: string
          avatar_url: string | null
          created_at: string
          full_name: string | null
          id: string
          phone_e164: string | null
          updated_at: string
        }
        Insert: {
          account_status?: string
          avatar_url?: string | null
          created_at?: string
          full_name?: string | null
          id: string
          phone_e164?: string | null
          updated_at?: string
        }
        Update: {
          account_status?: string
          avatar_url?: string | null
          created_at?: string
          full_name?: string | null
          id?: string
          phone_e164?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      ride_chain_offers: {
        Row: {
          activated_at: string | null
          created_at: string
          current_ride_id: string
          distance_from_current_destination_m: number
          driver_id: string
          estimated_remaining_distance_m: number | null
          estimated_seconds_to_destination: number | null
          expires_at: string
          id: string
          next_ride_id: string
          offered_at: string
          responded_at: string | null
          status: string
        }
        Insert: {
          activated_at?: string | null
          created_at?: string
          current_ride_id: string
          distance_from_current_destination_m: number
          driver_id: string
          estimated_remaining_distance_m?: number | null
          estimated_seconds_to_destination?: number | null
          expires_at: string
          id?: string
          next_ride_id: string
          offered_at?: string
          responded_at?: string | null
          status?: string
        }
        Update: {
          activated_at?: string | null
          created_at?: string
          current_ride_id?: string
          distance_from_current_destination_m?: number
          driver_id?: string
          estimated_remaining_distance_m?: number | null
          estimated_seconds_to_destination?: number | null
          expires_at?: string
          id?: string
          next_ride_id?: string
          offered_at?: string
          responded_at?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "ride_chain_offers_current_ride_id_fkey"
            columns: ["current_ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ride_chain_offers_next_ride_id_fkey"
            columns: ["next_ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_commissions: {
        Row: {
          business_model_snapshot: string
          commercial_config_id: string
          commission_amount: number
          commission_percent_snapshot: number
          created_at: string
          currency: string
          driver_id: string
          fare_amount: number
          pincode_id: number
          ride_id: string
          settled_at: string | null
          settlement_status: string
        }
        Insert: {
          business_model_snapshot: string
          commercial_config_id: string
          commission_amount: number
          commission_percent_snapshot: number
          created_at?: string
          currency?: string
          driver_id: string
          fare_amount: number
          pincode_id: number
          ride_id: string
          settled_at?: string | null
          settlement_status?: string
        }
        Update: {
          business_model_snapshot?: string
          commercial_config_id?: string
          commission_amount?: number
          commission_percent_snapshot?: number
          created_at?: string
          currency?: string
          driver_id?: string
          fare_amount?: number
          pincode_id?: number
          ride_id?: string
          settled_at?: string | null
          settlement_status?: string
        }
        Relationships: [
          {
            foreignKeyName: "ride_commissions_commercial_config_id_fkey"
            columns: ["commercial_config_id"]
            isOneToOne: false
            referencedRelation: "service_area_commercial_configs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ride_commissions_pincode_id_fkey"
            columns: ["pincode_id"]
            isOneToOne: false
            referencedRelation: "service_area_pincodes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ride_commissions_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: true
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_dispatch_attempts: {
        Row: {
          attempted_at: string
          id: string
          offered_driver_count: number
          result: string
          ride_id: string
          search_radius_m: number
        }
        Insert: {
          attempted_at?: string
          id?: string
          offered_driver_count?: number
          result: string
          ride_id: string
          search_radius_m: number
        }
        Update: {
          attempted_at?: string
          id?: string
          offered_driver_count?: number
          result?: string
          ride_id?: string
          search_radius_m?: number
        }
        Relationships: [
          {
            foreignKeyName: "ride_dispatch_attempts_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_events: {
        Row: {
          actor_user_id: string | null
          created_at: string
          details: Json
          event_type: string
          id: number
          new_status: string | null
          previous_status: string | null
          ride_id: string
        }
        Insert: {
          actor_user_id?: string | null
          created_at?: string
          details?: Json
          event_type: string
          id?: never
          new_status?: string | null
          previous_status?: string | null
          ride_id: string
        }
        Update: {
          actor_user_id?: string | null
          created_at?: string
          details?: Json
          event_type?: string
          id?: never
          new_status?: string | null
          previous_status?: string | null
          ride_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "ride_events_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_location_points: {
        Row: {
          accuracy_m: number | null
          driver_id: string
          geohash_7: string | null
          heading_degrees: number | null
          id: number
          location: unknown
          recorded_at: string
          ride_id: string
          speed_mps: number | null
        }
        Insert: {
          accuracy_m?: number | null
          driver_id: string
          geohash_7?: string | null
          heading_degrees?: number | null
          id?: never
          location: unknown
          recorded_at?: string
          ride_id: string
          speed_mps?: number | null
        }
        Update: {
          accuracy_m?: number | null
          driver_id?: string
          geohash_7?: string | null
          heading_degrees?: number | null
          id?: never
          location?: unknown
          recorded_at?: string
          ride_id?: string
          speed_mps?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "ride_location_points_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_offers: {
        Row: {
          driver_id: string
          expires_at: string
          id: string
          offered_at: string
          responded_at: string | null
          ride_id: string
          status: string
        }
        Insert: {
          driver_id: string
          expires_at: string
          id?: string
          offered_at?: string
          responded_at?: string | null
          ride_id: string
          status?: string
        }
        Update: {
          driver_id?: string
          expires_at?: string
          id?: string
          offered_at?: string
          responded_at?: string | null
          ride_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "ride_offers_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_otp_attempts: {
        Row: {
          attempted_at: string
          driver_id: string
          id: number
          ride_id: string
          succeeded: boolean
        }
        Insert: {
          attempted_at?: string
          driver_id: string
          id?: never
          ride_id: string
          succeeded: boolean
        }
        Update: {
          attempted_at?: string
          driver_id?: string
          id?: never
          ride_id?: string
          succeeded?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "ride_otp_attempts_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_safety_events: {
        Row: {
          actor_user_id: string
          created_at: string
          details: Json
          event_type: string
          id: string
          location: unknown
          ride_id: string
        }
        Insert: {
          actor_user_id: string
          created_at?: string
          details?: Json
          event_type: string
          id?: string
          location?: unknown
          ride_id: string
        }
        Update: {
          actor_user_id?: string
          created_at?: string
          details?: Json
          event_type?: string
          id?: string
          location?: unknown
          ride_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "ride_safety_events_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      ride_support_tickets: {
        Row: {
          assigned_to: string | null
          category: string
          created_at: string
          description: string
          id: string
          priority: string
          ride_id: string | null
          status: string
          subject: string
          submitted_by: string
          updated_at: string
        }
        Insert: {
          assigned_to?: string | null
          category: string
          created_at?: string
          description: string
          id?: string
          priority?: string
          ride_id?: string | null
          status?: string
          subject: string
          submitted_by: string
          updated_at?: string
        }
        Update: {
          assigned_to?: string | null
          category?: string
          created_at?: string
          description?: string
          id?: string
          priority?: string
          ride_id?: string | null
          status?: string
          subject?: string
          submitted_by?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "ride_support_tickets_ride_id_fkey"
            columns: ["ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
        ]
      }
      rides: {
        Row: {
          accepted_at: string | null
          actual_distance_m: number | null
          actual_duration_s: number | null
          booking_idempotency_key: string | null
          cancellation_reason: string | null
          cancelled_at: string | null
          chain_from_ride_id: string | null
          commercial_config_id: string | null
          commercial_model_snapshot: string | null
          commercial_terms_snapshot: Json
          completed_at: string | null
          created_at: string
          currency: string
          customer_id: string
          destination_address: string
          destination_location: unknown
          driver_id: string | null
          estimated_distance_m: number | null
          estimated_duration_s: number | null
          estimated_fare: number | null
          fare_breakdown: Json
          fare_config_id: number | null
          fare_config_snapshot: Json
          final_fare: number | null
          final_fare_breakdown: Json
          id: string
          pickup_address: string
          pickup_location: unknown
          pickup_otp_hash: string | null
          pincode_id: number | null
          requested_at: string
          service_area_id: number | null
          started_at: string | null
          status: string
          updated_at: string
          vehicle_category_id: number
        }
        Insert: {
          accepted_at?: string | null
          actual_distance_m?: number | null
          actual_duration_s?: number | null
          booking_idempotency_key?: string | null
          cancellation_reason?: string | null
          cancelled_at?: string | null
          chain_from_ride_id?: string | null
          commercial_config_id?: string | null
          commercial_model_snapshot?: string | null
          commercial_terms_snapshot?: Json
          completed_at?: string | null
          created_at?: string
          currency?: string
          customer_id: string
          destination_address: string
          destination_location: unknown
          driver_id?: string | null
          estimated_distance_m?: number | null
          estimated_duration_s?: number | null
          estimated_fare?: number | null
          fare_breakdown?: Json
          fare_config_id?: number | null
          fare_config_snapshot?: Json
          final_fare?: number | null
          final_fare_breakdown?: Json
          id?: string
          pickup_address: string
          pickup_location: unknown
          pickup_otp_hash?: string | null
          pincode_id?: number | null
          requested_at?: string
          service_area_id?: number | null
          started_at?: string | null
          status?: string
          updated_at?: string
          vehicle_category_id: number
        }
        Update: {
          accepted_at?: string | null
          actual_distance_m?: number | null
          actual_duration_s?: number | null
          booking_idempotency_key?: string | null
          cancellation_reason?: string | null
          cancelled_at?: string | null
          chain_from_ride_id?: string | null
          commercial_config_id?: string | null
          commercial_model_snapshot?: string | null
          commercial_terms_snapshot?: Json
          completed_at?: string | null
          created_at?: string
          currency?: string
          customer_id?: string
          destination_address?: string
          destination_location?: unknown
          driver_id?: string | null
          estimated_distance_m?: number | null
          estimated_duration_s?: number | null
          estimated_fare?: number | null
          fare_breakdown?: Json
          fare_config_id?: number | null
          fare_config_snapshot?: Json
          final_fare?: number | null
          final_fare_breakdown?: Json
          id?: string
          pickup_address?: string
          pickup_location?: unknown
          pickup_otp_hash?: string | null
          pincode_id?: number | null
          requested_at?: string
          service_area_id?: number | null
          started_at?: string | null
          status?: string
          updated_at?: string
          vehicle_category_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "rides_chain_from_ride_id_fkey"
            columns: ["chain_from_ride_id"]
            isOneToOne: false
            referencedRelation: "rides"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rides_commercial_config_id_fkey"
            columns: ["commercial_config_id"]
            isOneToOne: false
            referencedRelation: "service_area_commercial_configs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rides_fare_config_id_fkey"
            columns: ["fare_config_id"]
            isOneToOne: false
            referencedRelation: "fare_configs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rides_pincode_id_fkey"
            columns: ["pincode_id"]
            isOneToOne: false
            referencedRelation: "service_area_pincodes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rides_service_area_id_fkey"
            columns: ["service_area_id"]
            isOneToOne: false
            referencedRelation: "service_areas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "rides_vehicle_category_id_fkey"
            columns: ["vehicle_category_id"]
            isOneToOne: false
            referencedRelation: "vehicle_categories"
            referencedColumns: ["id"]
          },
        ]
      }
      service_area_commercial_configs: {
        Row: {
          business_model: string
          commission_percent: number | null
          created_at: string
          created_by: string | null
          currency: string
          id: string
          is_active: boolean
          pincode_id: number
          subscription_amount: number | null
          subscription_period: string | null
          valid_from: string
          valid_until: string | null
        }
        Insert: {
          business_model: string
          commission_percent?: number | null
          created_at?: string
          created_by?: string | null
          currency?: string
          id?: string
          is_active?: boolean
          pincode_id: number
          subscription_amount?: number | null
          subscription_period?: string | null
          valid_from?: string
          valid_until?: string | null
        }
        Update: {
          business_model?: string
          commission_percent?: number | null
          created_at?: string
          created_by?: string | null
          currency?: string
          id?: string
          is_active?: boolean
          pincode_id?: number
          subscription_amount?: number | null
          subscription_period?: string | null
          valid_from?: string
          valid_until?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "service_area_commercial_configs_pincode_id_fkey"
            columns: ["pincode_id"]
            isOneToOne: false
            referencedRelation: "service_area_pincodes"
            referencedColumns: ["id"]
          },
        ]
      }
      service_area_dispatch_configs: {
        Row: {
          chain_offer_ttl_seconds: number
          chain_pickup_distance_m: number
          created_at: string
          id: number
          initial_radius_m: number
          location_max_age_seconds: number
          max_radius_m: number
          offer_batch_size: number
          offer_ttl_seconds: number
          pincode_id: number
          radius_step_m: number
          updated_at: string
        }
        Insert: {
          chain_offer_ttl_seconds?: number
          chain_pickup_distance_m?: number
          created_at?: string
          id?: never
          initial_radius_m?: number
          location_max_age_seconds?: number
          max_radius_m?: number
          offer_batch_size?: number
          offer_ttl_seconds?: number
          pincode_id: number
          radius_step_m?: number
          updated_at?: string
        }
        Update: {
          chain_offer_ttl_seconds?: number
          chain_pickup_distance_m?: number
          created_at?: string
          id?: never
          initial_radius_m?: number
          location_max_age_seconds?: number
          max_radius_m?: number
          offer_batch_size?: number
          offer_ttl_seconds?: number
          pincode_id?: number
          radius_step_m?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "service_area_dispatch_configs_pincode_id_fkey"
            columns: ["pincode_id"]
            isOneToOne: true
            referencedRelation: "service_area_pincodes"
            referencedColumns: ["id"]
          },
        ]
      }
      service_area_pincodes: {
        Row: {
          boundary: unknown
          created_at: string
          id: number
          is_active: boolean
          label: string | null
          pincode: string
          service_area_id: number
          updated_at: string
        }
        Insert: {
          boundary?: unknown
          created_at?: string
          id?: never
          is_active?: boolean
          label?: string | null
          pincode: string
          service_area_id: number
          updated_at?: string
        }
        Update: {
          boundary?: unknown
          created_at?: string
          id?: never
          is_active?: boolean
          label?: string | null
          pincode?: string
          service_area_id?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "service_area_pincodes_service_area_id_fkey"
            columns: ["service_area_id"]
            isOneToOne: false
            referencedRelation: "service_areas"
            referencedColumns: ["id"]
          },
        ]
      }
      service_areas: {
        Row: {
          boundary: unknown
          city: string
          country_code: string
          created_at: string
          id: number
          is_active: boolean
          name: string
          state: string
          timezone: string
          updated_at: string
        }
        Insert: {
          boundary?: unknown
          city: string
          country_code?: string
          created_at?: string
          id?: never
          is_active?: boolean
          name: string
          state: string
          timezone?: string
          updated_at?: string
        }
        Update: {
          boundary?: unknown
          city?: string
          country_code?: string
          created_at?: string
          id?: never
          is_active?: boolean
          name?: string
          state?: string
          timezone?: string
          updated_at?: string
        }
        Relationships: []
      }
      user_roles: {
        Row: {
          assigned_at: string
          assigned_by: string | null
          id: number
          role: string
          user_id: string
        }
        Insert: {
          assigned_at?: string
          assigned_by?: string | null
          id?: never
          role: string
          user_id: string
        }
        Update: {
          assigned_at?: string
          assigned_by?: string | null
          id?: never
          role?: string
          user_id?: string
        }
        Relationships: []
      }
      vehicle_categories: {
        Row: {
          code: string
          created_at: string
          description: string | null
          id: number
          is_active: boolean
          name: string
          sort_order: number
        }
        Insert: {
          code: string
          created_at?: string
          description?: string | null
          id?: never
          is_active?: boolean
          name: string
          sort_order?: number
        }
        Update: {
          code?: string
          created_at?: string
          description?: string | null
          id?: never
          is_active?: boolean
          name?: string
          sort_order?: number
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      accept_ride_offer: {
        Args: { p_driver_id: string; p_offer_id: string }
        Returns: Json
      }
      admin_review_driver_pincode: {
        Args: {
          p_actor: string
          p_decision: string
          p_note?: string
          p_request_id: string
        }
        Returns: Json
      }
      admin_set_pincode_boundary: {
        Args: { p_actor: string; p_geojson: Json; p_pincode_id: number }
        Returns: Json
      }
      admin_set_pincode_commercial_config: {
        Args: {
          p_actor: string
          p_business_model: string
          p_commission_percent?: number
          p_pincode_id: number
          p_subscription_amount?: number
          p_subscription_period?: string
          p_valid_from?: string
          p_valid_until?: string
        }
        Returns: Json
      }
      create_ride_booking: {
        Args: {
          p_booking_idempotency_key: string
          p_customer_id: string
          p_destination_address: string
          p_destination_latitude: number
          p_destination_longitude: number
          p_distance_m: number
          p_duration_s: number
          p_estimated_fare: number
          p_fare_breakdown: Json
          p_pickup_address: string
          p_pickup_latitude: number
          p_pickup_longitude: number
          p_pickup_otp_hash: string
          p_pincode: string
          p_vehicle_category_id: number
        }
        Returns: Json
      }
      create_ride_chain_offer_batch: {
        Args: { p_next_ride_id: string }
        Returns: Json
      }
      create_ride_offer_batch: {
        Args: { p_radius_m: number; p_ride_id: string }
        Returns: Json
      }
      customer_cancel_ride: {
        Args: { p_customer_id: string; p_reason: string; p_ride_id: string }
        Returns: Json
      }
      driver_ride_transition: {
        Args: {
          p_action: string
          p_driver_id: string
          p_otp_sha256?: string
          p_ride_id: string
        }
        Returns: Json
      }
      find_nearby_drivers: {
        Args: {
          p_limit?: number
          p_pickup_ewkt: string
          p_pincode_id: number
          p_radius_m: number
          p_ride_id: string
          p_vehicle_category_id: number
        }
        Returns: {
          distance_m: number
          driver_id: string
          geohash_7: string
          location_recorded_at: string
        }[]
      }
      find_ride_chain_candidates: {
        Args: { p_next_ride_id: string }
        Returns: {
          current_ride_id: string
          distance_to_next_pickup_m: number
          driver_id: string
          estimated_seconds_to_destination: number
          expires_in_seconds: number
          remaining_distance_m: number
        }[]
      }
      finish_ride: {
        Args: { p_driver_id: string; p_final_fare: number; p_ride_id: string }
        Returns: Json
      }
      finish_ride_from_track: {
        Args: { p_driver_id: string; p_ride_id: string }
        Returns: Json
      }
      get_customer_ride_tracking: { Args: { p_ride_id: string }; Returns: Json }
      get_driver_ride_completion_context: {
        Args: { p_driver_id: string; p_ride_id: string }
        Returns: Json
      }
      get_ride_dispatch_context: { Args: { p_ride_id: string }; Returns: Json }
      get_ride_quote_context: {
        Args: {
          p_pickup_latitude: number
          p_pickup_longitude: number
          p_pincode: string
          p_vehicle_category_id: number
        }
        Returns: Json
      }
      preaccept_ride_chain_offer: {
        Args: { p_chain_offer_id: string; p_driver_id: string }
        Returns: Json
      }
      record_driver_ride_location: {
        Args: {
          p_accuracy_m: number
          p_driver_id: string
          p_heading_degrees: number
          p_latitude: number
          p_longitude: number
          p_recorded_at?: string
          p_speed_mps: number
        }
        Returns: Json
      }
      reject_ride_offer: {
        Args: { p_driver_id: string; p_offer_id: string }
        Returns: Json
      }
      request_driver_service_pincode: {
        Args: { p_driver_id: string; p_is_primary?: boolean; p_pincode: string }
        Returns: Json
      }
      rotate_ride_pickup_otp: {
        Args: { p_customer_id: string; p_otp_sha256: string; p_ride_id: string }
        Returns: Json
      }
      set_driver_availability: {
        Args: { p_driver_id: string; p_online: boolean; p_pincode: string }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
