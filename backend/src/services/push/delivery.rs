use a2::{
    request::payload::PayloadLike, Client as ApnsClient, ClientConfig as ApnsClientConfig,
    DefaultNotificationBuilder, Endpoint as ApnsEndpoint, ErrorReason as ApnsErrorReason,
    NotificationBuilder, NotificationOptions, Priority as ApnsPriority, PushType as ApnsPushType,
};
use std::fs::File;
use tracing::{error, warn};
use web_push::WebPushClient;

use crate::models::{PushEnvironment, PushProvider, PushSubscription};

use super::payload::ApnsNotification;
use super::PushService;

const APNS_CUSTOM_DATA_ROOT: &str = "wettyChat";

#[derive(Debug)]
struct PayloadWithThreadId<'a> {
    inner: a2::request::payload::Payload<'a>,
    thread_id: String,
}

impl serde::Serialize for PayloadWithThreadId<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::Error as _;
        let mut value = serde_json::to_value(&self.inner).map_err(S::Error::custom)?;
        if let Some(aps) = value
            .as_object_mut()
            .and_then(|o| o.get_mut("aps"))
            .and_then(|v| v.as_object_mut())
        {
            aps.insert(
                "thread-id".to_string(),
                serde_json::Value::String(self.thread_id.clone()),
            );
        }
        value.serialize(serializer)
    }
}

impl PayloadLike for PayloadWithThreadId<'_> {
    fn get_device_token(&self) -> &str {
        self.inner.get_device_token()
    }
    fn get_options(&self) -> &NotificationOptions<'_> {
        self.inner.get_options()
    }
}

#[derive(Debug, Clone)]
pub(super) struct ApnsSender {
    sandbox_client: ApnsClient,
    production_client: ApnsClient,
    topic: String,
}

pub(super) enum SendFailure {
    Stale(i64),
    Transient,
}

impl PushService {
    pub(super) async fn send_to_subscription(
        &self,
        sub: &PushSubscription,
        web_payload: &[u8],
        apns_notification: &ApnsNotification,
    ) -> Result<(), SendFailure> {
        match sub.provider {
            PushProvider::WebPush => self.send_web_push(sub, web_payload).await,
            PushProvider::Apns => self.send_apns_push(sub, apns_notification).await,
        }
    }

    async fn send_web_push(
        &self,
        sub: &PushSubscription,
        payload: &[u8],
    ) -> Result<(), SendFailure> {
        let endpoint = match &sub.endpoint {
            Some(endpoint) => endpoint.clone(),
            None => {
                self.metrics
                    .record_push_notification(PushProvider::WebPush.as_metrics_label(), false);
                warn!("web push subscription {} missing endpoint", sub.id);
                return Err(SendFailure::Stale(sub.id));
            }
        };
        let data = match sub.web_push_data() {
            Ok(data) => data,
            Err(e) => {
                self.metrics
                    .record_push_notification(PushProvider::WebPush.as_metrics_label(), false);
                warn!(
                    "web push subscription {} has invalid provider data: {:?}",
                    sub.id, e
                );
                return Err(SendFailure::Stale(sub.id));
            }
        };

        let subscription_info =
            web_push::SubscriptionInfo::new(endpoint.clone(), data.p256dh, data.auth);

        let sig_builder =
            match web_push::VapidSignatureBuilder::from_base64_no_sub(&self.vapid_private_key) {
                Ok(b) => b,
                Err(e) => {
                    error!(
                        "Vapid config error (should have been caught on startup): {:?}",
                        e
                    );
                    self.metrics
                        .record_push_notification(PushProvider::WebPush.as_metrics_label(), false);
                    return Err(SendFailure::Transient);
                }
            };

        let mut b = sig_builder.add_sub_info(&subscription_info);
        b.add_claim("sub", self.vapid_subject.clone());
        let signature = match b.build() {
            Ok(sig) => sig,
            Err(e) => {
                error!("Failed to build VAPID signature: {:?}", e);
                self.metrics
                    .record_push_notification(PushProvider::WebPush.as_metrics_label(), false);
                return Err(SendFailure::Transient);
            }
        };

        let mut builder = web_push::WebPushMessageBuilder::new(&subscription_info);
        builder.set_payload(web_push::ContentEncoding::Aes128Gcm, payload);
        builder.set_vapid_signature(signature);

        match builder.build() {
            Ok(message) => match self.client.send(message).await {
                Ok(_) => {
                    self.metrics
                        .record_push_notification(PushProvider::WebPush.as_metrics_label(), true);
                    Ok(())
                }
                Err(e) => {
                    self.metrics
                        .record_push_notification(PushProvider::WebPush.as_metrics_label(), false);
                    if matches!(
                        e,
                        web_push::WebPushError::EndpointNotValid(_)
                            | web_push::WebPushError::EndpointNotFound(_)
                    ) {
                        warn!("stale web push subscription for endpoint {}", endpoint);
                        Err(SendFailure::Stale(sub.id))
                    } else {
                        error!("Failed to send web push notification: {:?}", e);
                        Err(SendFailure::Transient)
                    }
                }
            },
            Err(e) => {
                error!("Failed to build web push message: {:?}", e);
                self.metrics
                    .record_push_notification(PushProvider::WebPush.as_metrics_label(), false);
                Err(SendFailure::Transient)
            }
        }
    }

    async fn send_apns_push(
        &self,
        sub: &PushSubscription,
        notification: &ApnsNotification,
    ) -> Result<(), SendFailure> {
        let sender = match &self.apns_sender {
            Some(sender) => sender,
            None => {
                warn!(
                    "received APNs subscription {} without APNs sender configured",
                    sub.id
                );
                self.metrics
                    .record_push_notification(PushProvider::Apns.as_metrics_label(), false);
                return Err(SendFailure::Transient);
            }
        };
        let device_token = match &sub.device_token {
            Some(token) => token.as_str(),
            None => {
                warn!("APNs subscription {} missing device token", sub.id);
                self.metrics
                    .record_push_notification(PushProvider::Apns.as_metrics_label(), false);
                return Err(SendFailure::Stale(sub.id));
            }
        };
        if let Err(e) = sub.apns_data() {
            warn!(
                "APNs subscription {} has invalid provider data: {:?}",
                sub.id, e
            );
            self.metrics
                .record_push_notification(PushProvider::Apns.as_metrics_label(), false);
            return Err(SendFailure::Stale(sub.id));
        }
        let environment = match sub.apns_environment {
            Some(environment) => environment,
            None => {
                warn!("APNs subscription {} missing environment", sub.id);
                self.metrics
                    .record_push_notification(PushProvider::Apns.as_metrics_label(), false);
                return Err(SendFailure::Stale(sub.id));
            }
        };

        match sender.send(device_token, &environment, notification).await {
            Ok(()) => {
                self.metrics
                    .record_push_notification(PushProvider::Apns.as_metrics_label(), true);
                Ok(())
            }
            Err(ApnsSendError::Stale(reason)) => {
                warn!(
                    "stale APNs subscription {} for token {}: {:?}",
                    sub.id, device_token, reason
                );
                self.metrics
                    .record_push_notification(PushProvider::Apns.as_metrics_label(), false);
                Err(SendFailure::Stale(sub.id))
            }
            Err(ApnsSendError::Transient(reason)) => {
                error!(
                    "failed to send APNs notification for subscription {}: {}",
                    sub.id, reason
                );
                self.metrics
                    .record_push_notification(PushProvider::Apns.as_metrics_label(), false);
                Err(SendFailure::Transient)
            }
        }
    }
}

#[derive(Debug)]
enum ApnsSendError {
    Stale(ApnsErrorReason),
    Transient(String),
}

impl ApnsSender {
    pub(super) fn from_env() -> Result<Option<Self>, String> {
        let key_id = std::env::var("APNS_KEY_ID").ok();
        let team_id = std::env::var("APNS_TEAM_ID").ok();
        let private_key_path = std::env::var("APNS_PRIVATE_KEY_PATH").ok();
        let topic = std::env::var("APNS_TOPIC").ok();

        if key_id.is_none() && team_id.is_none() && private_key_path.is_none() && topic.is_none() {
            return Ok(None);
        }

        let key_id = key_id.ok_or_else(|| "APNS_KEY_ID must be set".to_string())?;
        let team_id = team_id.ok_or_else(|| "APNS_TEAM_ID must be set".to_string())?;
        let private_key_path =
            private_key_path.ok_or_else(|| "APNS_PRIVATE_KEY_PATH must be set".to_string())?;
        let topic = topic.ok_or_else(|| "APNS_TOPIC must be set".to_string())?;

        let sandbox_client =
            Self::build_client(&private_key_path, &key_id, &team_id, ApnsEndpoint::Sandbox)?;
        let production_client = Self::build_client(
            &private_key_path,
            &key_id,
            &team_id,
            ApnsEndpoint::Production,
        )?;

        Ok(Some(Self {
            sandbox_client,
            production_client,
            topic,
        }))
    }

    fn build_client(
        private_key_path: &str,
        key_id: &str,
        team_id: &str,
        endpoint: ApnsEndpoint,
    ) -> Result<ApnsClient, String> {
        let mut file = File::open(private_key_path)
            .map_err(|e| format!("failed to open APNS private key: {:?}", e))?;
        let config = ApnsClientConfig {
            endpoint,
            ..Default::default()
        };
        ApnsClient::token(&mut file, key_id, team_id, config)
            .map_err(|e| format!("failed to initialize APNS client: {:?}", e))
    }

    async fn send(
        &self,
        device_token: &str,
        environment: &PushEnvironment,
        notification: &ApnsNotification,
    ) -> Result<(), ApnsSendError> {
        let title_loc_args = [notification.title_loc_args[0].as_str()];
        let body_loc_args: Vec<&str> = notification
            .body_loc_args
            .iter()
            .map(String::as_str)
            .collect();
        let builder = DefaultNotificationBuilder::new()
            .set_title_loc_key(notification.title_loc_key)
            .set_title_loc_args(&title_loc_args)
            .set_loc_key(notification.body_loc_key)
            .set_loc_args(&body_loc_args)
            .set_badge(notification.badge)
            .set_sound("default");
        let options = NotificationOptions {
            apns_push_type: Some(ApnsPushType::Alert),
            apns_priority: Some(ApnsPriority::High),
            apns_topic: Some(self.topic.as_str()),
            ..Default::default()
        };

        let mut inner_payload = builder.build(device_token, options);
        inner_payload
            .add_custom_data(APNS_CUSTOM_DATA_ROOT, &notification.custom_data)
            .map_err(|e| {
                ApnsSendError::Transient(format!("failed to serialize APNs payload: {:?}", e))
            })?;
        let payload = PayloadWithThreadId {
            inner: inner_payload,
            thread_id: notification.thread_id.clone(),
        };

        let client = match environment {
            PushEnvironment::Sandbox => &self.sandbox_client,
            PushEnvironment::Production => &self.production_client,
        };
        let response = client
            .send(payload)
            .await
            .map_err(|e| ApnsSendError::Transient(format!("{:?}", e)))?;

        if response.code == 200 {
            Ok(())
        } else if let Some(error) = response.error {
            if is_stale_apns_error_reason(&error.reason) {
                Err(ApnsSendError::Stale(error.reason))
            } else {
                Err(ApnsSendError::Transient(format!("{:?}", error.reason)))
            }
        } else {
            Err(ApnsSendError::Transient(format!(
                "APNs request failed with status {}",
                response.code
            )))
        }
    }
}

pub(super) fn is_stale_apns_error_reason(reason: &ApnsErrorReason) -> bool {
    matches!(
        reason,
        ApnsErrorReason::BadDeviceToken
            | ApnsErrorReason::DeviceTokenNotForTopic
            | ApnsErrorReason::Unregistered
    )
}
