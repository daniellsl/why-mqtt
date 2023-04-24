package why.mqtt.client;

import haxe.Constraints;
import tink.Chunk;
import why.mqtt.Client;

using tink.CoreApi;

class MqttJsClient extends BaseClient {
	final config:MqttJsClientConfig;
	var native:Native;

	public function new(config:MqttJsClientConfig) {
		super();
		this.config = config;
	}
	
	function doConnect():Promise<Noise> {
		return if(native != null) {
			new Error(Conflict, 'Already attempted to connect');
		} else {
			new Promise((resolve, reject) -> {
				try {
					native = Native.connect(config.url, {
						keepalive: config.keepAlive,
						clientId: config.clientId,
						protocolVersion: config.version,
						clean: config.cleanSession,
						username: config.username,
						password: config.password,
						reconnectPeriod: config.reconnectPeriod,
						will: switch config.willMessage {
							case null: null;
							case will: {
								topic: will.topic,
								payload: Buffer.fromChunk(will.payload),
								qos: will.qos,
								retain: will.retain,
							}
						}
					});

					var initBindings:CallbackLink = null;
					native.once('connect', function onConnect() {
						haxe.Timer.delay(resolve.bind(Noise), 0);  // there may be error right after connect and we should prioritize that
						initBindings.cancel();
						var bindings:CallbackLink = null;
						
						native.on('close', function onClose() {
							disconnectedTrigger.trigger(Noise);
							if(config.reconnectPeriod == 0) bindings.cancel();
						});
						native.on('message', function onMessage(topic, payload:Buffer, packet) messageReceivedTrigger.trigger(new Message(topic, payload, packet.qos, packet.retain)));
						bindings = [
							native.off.bind('close', onClose),
							native.off.bind('message', onMessage)
						];
					});
					native.once('error', function onConnectFail(err) {
						if(config.reconnectPeriod == 0) {
							initBindings.cancel();
							reject(Error.ofJsError(err));
						}
					});
					// SO, Problem comes in here, why???
					initBindings = [
						native.off.bind('connect', onConnect),
						native.off.bind('error', onConnectFail),
					];
				}
				catch(e)
					reject(Error.withData('Native driver failed to connect', e));
				
				null; // TODO
			});
		}
	}

	function doPublish(message:Message):Promise<Noise> {
		return new Promise((resolve, reject) -> {
			native.publish(
				message.topic,
				message.payload,
				{qos: message.qos, retain: message.retain},
				err -> err == null ? resolve(Noise) : reject(Error.ofJsError(err))
			);
			null; // TODO
		});
	}

	function doSubscribe(topic:Topic, ?options:SubscribeOptions):Promise<Subscription> {
		return new Promise((resolve, reject) -> {
			native.subscribe(
				topic,
				options,
				(err, granted) -> {
					if(err != null)
						reject(Error.ofJsError(err))
					else switch granted[0] {
						case null:
							// TODO: this is likely because already subscribed
							reject(new Error('Failed to subscribe (no grant)'));
						case v if((v.qos:Int) == 128):
							reject(new Error('Failed to subscribe (SUBACK: 128)'));
						case v:
							resolve(new Subscription(() -> native.unsubscribe(v.topic), v.topic, v.qos));
					}
				}
			);
			null; // TODO
		});
	}
	
	function doClose():Promise<Noise> {
		// needs to clean up event listeners?
		return new Promise((resolve, reject) -> {
			messageReceivedTrigger.clear();
			native.end(err -> err == null ? resolve(Noise) : reject(Error.ofJsError(err)));
			native = null;
			null; // TODO
		});
	}
	
	function get_active() {
		return native != null;
	}
}

// TODO: expose more vendor-specific configs
typedef MqttJsClientConfig = Config & {
	final url:String;
	final ?reconnectPeriod:Int;
}

#if (nodejs || mqttjs.global)
@:jsRequire('mqtt')
#else
@:native('mqtt')
#end
extern class Native {
	static function connect(url:String, options:{}):Native;
	function on(event:String, f:Function):Void;
	function once(event:String, f:Function):Void;
	function off(event:String, f:Function):Void;
	function publish(topic:String, payload:Buffer, options:{}, cb:(err:js.lib.Error)->Void):Void;
	function subscribe(topic:String, options:{}, cb:(err:js.lib.Error, granted:Array<{topic:String, qos:Qos}>)->Void):Void;
	function unsubscribe(topic:String, ?cb:(err:js.lib.Error)->Void):Void;
	function end(cb:(err:js.lib.Error)->Void):Void;
}


private typedef BufferImpl = #if nodejs js.node.Buffer #else js.lib.Uint8Array #end;

private abstract Buffer(BufferImpl) from BufferImpl to BufferImpl {
	@:from
	public static inline function fromChunk(chunk:Chunk):Buffer {
		return #if nodejs js.node.Buffer.hxFromBytes(chunk.toBytes()); #else new js.lib.Uint8Array(chunk.toBytes().getData()); #end
	}
	
	@:to
	public inline function toChunk():Chunk {
		return this;
	}
}

