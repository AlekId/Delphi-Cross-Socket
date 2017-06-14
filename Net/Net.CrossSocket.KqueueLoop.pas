{******************************************************************************}
{                                                                              }
{       Delphi cross platform socket library                                   }
{                                                                              }
{       Copyright (c) 2017 WiNDDRiVER(soulawing@gmail.com)                     }
{                                                                              }
{       Homepage: https://github.com/winddriver/Delphi-Cross-Socket            }
{                                                                              }
{******************************************************************************}
unit Net.CrossSocket.KqueueLoop;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Posix.SysSocket, Posix.NetinetIn, Posix.UniStd, Posix.NetDB, Posix.Errno,
  BSD.kqueue, Net.SocketAPI, Net.CrossSocket.EventLoop;

type
  // KQUEUE �� EPOLL ���еĲ���
  //    KQUEUE�Ķ�����, һ��Socket��������ж�����¼, ÿ���¼�һ��,
  //    ��һ��� EPOLL ��һ��, EPOLL��ÿ��Socket���ֻ����һ����¼
  //    Ҫ������¼�ʱ, ֻ��Ҫ������¼���λ�������һ����� epoll_ctl ����
  //
  // EV_DISPATCH �� EV_CLEAR ���� kqueue ֧���̳߳صĹؼ�
  //    �ò�����Ͽ������¼������������������, ������ͬһ��Socket��ͬһ���¼�
  //    ͬʱ����������̴߳���
  //
  // EVFILT_READ
  //    ���ڼ����ջ������Ƿ�ɶ���
  //    ���ڼ���Socket��˵,��ʾ���µ����ӵ���
  //    ���������ӵ�Socket��˵,��ʾ�����ݵ�����ջ�����
  //    Ϊ��֧���̳߳�, ������ϲ��� EV_CLEAR or EV_DISPATCH
  //    �ò�����ϱ�ʾ, ���¼�һ����������������¼���״̬��������
  //    ���������ӻ��߶�ȡ����֮����Ͷ��һ�� EVFILT_READ, ���ϲ���
  //    EV_ENABLE or EV_CLEAR or EV_DISPATCH, ���¼��������
  //
  // EVFILT_WRITE
  //    ���ڼ�ⷢ�ͻ������Ƿ��д��
  //    ����Connect�е�Socket,Ͷ��EV_ENABLE,�ȵ��¼�����ʱ��ʾ�����ѽ���
  //    ���������ӵ�Socket,��Send֮������Ͷ��EVFILT_WRITE,�ȵ��¼�����ʱ��ʾ�������
  //    ����EVFILT_WRITE��Ӧ�ô���EV_ONESHOT����,�ø��¼�ֻ�ᱻ����һ��
  //    ����,ֻҪ���ͻ������ǿյ�,���¼��ͻ�һֱ����,�Ⲣû��ʲô����
  //    ����ֻ��Ҫ��EVFILT_WRITEȥ������ӻ��߷����Ƿ�ɹ�
  //
  // KQUEUE ��������
  //    ��õ������ǽ�ʵ�ʷ������ݵĶ����ŵ� EVFILT_WRITE ����ʱ����, ��
  //    �¼��������� Socket ���ͻ����п��пռ��ˡ�IOCP����ֱ�ӽ������͵����ݼ�
  //    �ص�ͬʱ�Ӹ� WSASend, ������ɺ�ȥ���ûص�����; KQUEUE ���Ʋ�һ��, �� KQUEUE
  //    ��û������ WSASend �ĺ���, ֻ������ά���������ݼ��ص��Ķ���
  //    EPOLLҪ֧�ֶ��̲߳����������ݱ��봴�����Ͷ���, ����ͬһ�� Socket �Ĳ�������
  //    ���п�����һ���ֻᱻ�������͸��ǵ�
  TKqueueLoop = class(TAbstractEventLoop)
  private const
    MAX_EVENT_COUNT = 64;
  private type
    TKqueueAction = (kqAccept, kqConnect, kqRead, kqWrite);

    PPerIoData = ^TPerIoData;
    TPerIoData = record
      Action: TKqueueAction;
      Socket: THandle;
      Callback: TProc<THandle, Boolean>;
    end;

    PSendItem = ^TSendItem;
    TSendItem = record
      Data: PByte;
      Size: Integer;
      Callback: TProc<THandle, Boolean>;
    end;
  private
    FKqueueHandle: THandle;
    FIoThreads: TArray<TIoEventThread>;
    FSendQueue: TObjectDictionary<THandle, TList<PSendItem>>;
    class threadvar FEventList: array [0..MAX_EVENT_COUNT-1] of TKEvent;

    function NewIoData: PPerIoData;
    procedure FreeIoData(P: PPerIoData);
    procedure SetNoSigPipe(ASocket: THandle);

    function _KqueueCtl(op: word; fd: THandle; events: SmallInt;
      act: TKqueueAction; cb: TProc<THandle, Boolean> = nil): Boolean;

    procedure _ClearSendQueue(ASocketSendQueue: TList<PSendItem>);
    procedure _ClearAllSendQueue;
  protected
    procedure TriggerConnected(ASocket: THandle; AConnectType: Integer); override;
    procedure TriggerDisconnected(ASocket: THandle); override;

    procedure StartLoop; override;
    procedure StopLoop; override;

    function Listen(const AHost: string; APort: Word;
      const ACallback: TProc<THandle, Boolean> = nil): Integer; override;
    function Connect(const AHost: string; APort: Word;
      const ACallback: TProc<THandle, Boolean> = nil): Integer; override;
    function Send(ASocket: THandle; const ABuf; ALen: Integer;
      const ACallback: TProc<THandle, Boolean> = nil): Integer; override;

    function ProcessIoEvent: Boolean; override;
  public
    constructor Create(AIoThreads: Integer); override;
    destructor Destroy; override;
  end;

implementation

{ TKqueueLoop }

constructor TKqueueLoop.Create(AIoThreads: Integer);
begin
  inherited Create(AIoThreads);

  FSendQueue := TObjectDictionary<THandle, TList<PSendItem>>.Create([doOwnsValues]);
end;

destructor TKqueueLoop.Destroy;
begin
  System.TMonitor.Enter(FSendQueue);
  try
    _ClearAllSendQueue;
  finally
    System.TMonitor.Exit(FSendQueue);
  end;
  FreeAndNil(FSendQueue);

  inherited Destroy;
end;

function TKqueueLoop.NewIoData: PPerIoData;
begin
  System.New(Result);
  FillChar(Result^, SizeOf(TPerIoData), 0);
end;

procedure TKqueueLoop.FreeIoData(P: PPerIoData);
begin
  System.Dispose(P);
end;

procedure TKqueueLoop._ClearSendQueue(ASocketSendQueue: TList<PSendItem>);
var
  LSendItem: PSendItem;
begin
  for LSendItem in ASocketSendQueue do
    System.Dispose(LSendItem);

  ASocketSendQueue.Clear;
end;

procedure TKqueueLoop._ClearAllSendQueue;
var
  LPair: TPair<THandle, TList<PSendItem>>;
begin
  for LPair in FSendQueue do
    _ClearSendQueue(LPair.Value);

  FSendQueue.Clear;
end;

function TKqueueLoop._KqueueCtl(op: word; fd: THandle; events: SmallInt;
  act: TKqueueAction; cb: TProc<THandle, Boolean>): Boolean;
var
  LEvent: TKEvent;
  LPerIoData: PPerIoData;
begin
  LPerIoData := NewIoData;
  LPerIoData.Action := act;
  LPerIoData.Socket := fd;
  LPerIoData.Callback := cb;

  EV_SET(@LEvent, fd, events, op, 0, 0, Pointer(LPerIoData));
  if (kevent(FKqueueHandle, @LEvent, 1, nil, 0, nil) < 0) then
  begin
    FreeIoData(LPerIoData);
    Exit(False);
  end;

  Result := True;
end;

procedure TKqueueLoop.SetNoSigPipe(ASocket: THandle);
var
  LOptVal: Integer;
begin
  LOptVal := 1;
  TSocketAPI.SetSockOpt(ASocket, SOL_SOCKET, SO_NOSIGPIPE, LOptVal, SizeOf(Integer));
end;

procedure TKqueueLoop.StartLoop;
var
  I: Integer;
begin
  if (FIoThreads <> nil) then Exit;

  FKqueueHandle := kqueue();
  SetLength(FIoThreads, GetIoThreads);
  for I := 0 to Length(FIoThreads) - 1 do
    FIoThreads[i] := TIoEventThread.Create(Self);
end;

procedure TKqueueLoop.StopLoop;
var
  I: Integer;
begin
  if (FIoThreads = nil) then Exit;

  CloseAll;

  while (FListensCount > 0) or (FConnectionsCount > 0) do Sleep(1);

  Posix.UniStd.__close(FKqueueHandle);

  for I := 0 to Length(FIoThreads) - 1 do
  begin
    FIoThreads[I].WaitFor;
    FreeAndNil(FIoThreads[I]);
  end;
  FIoThreads := nil;
end;

procedure TKqueueLoop.TriggerConnected(ASocket: THandle; AConnectType: Integer);
var
  LSocketSendQueue: TList<PSendItem>;
begin
  // ��ȡSocket���Ͷ���
  System.TMonitor.Enter(FSendQueue);
  try
    if not FSendQueue.TryGetValue(ASocket, LSocketSendQueue) then
    begin
      LSocketSendQueue := TList<PSendItem>.Create;
      FSendQueue.AddOrSetValue(ASocket, LSocketSendQueue);
    end;
  finally
    System.TMonitor.Exit(FSendQueue);
  end;
end;

procedure TKqueueLoop.TriggerDisconnected(ASocket: THandle);
var
  LSocketSendQueue: TList<PSendItem>;
begin
  // �Ƴ�Socket���Ͷ���
  System.TMonitor.Enter(FSendQueue);
  try
    if FSendQueue.TryGetValue(ASocket, LSocketSendQueue) then
    begin
      // �����ǰSocket�����з��Ͷ���
      _ClearSendQueue(LSocketSendQueue);
      FSendQueue.Remove(ASocket);
    end;
  finally
    System.TMonitor.Exit(FSendQueue);
  end;
end;

function TKqueueLoop.Connect(const AHost: string; APort: Word;
  const ACallback: TProc<THandle, Boolean>): Integer;
  procedure _Failed1;
  begin
    {$IFDEF DEBUG}
    __RaiseLastOSError;
    {$ENDIF}

    TriggerConnectFailed(INVALID_HANDLE_VALUE);

    if Assigned(ACallback) then
      ACallback(INVALID_HANDLE_VALUE, False);
  end;

  function _Connect(ASocket: THandle; Addr: PRawAddrInfo): Boolean;
    procedure _Failed2;
    begin
      {$IFDEF DEBUG}
      __RaiseLastOSError;
      {$ENDIF}
      TSocketAPI.CloseSocket(ASocket);

      TriggerConnectFailed(ASocket);

      if Assigned(ACallback) then
        ACallback(ASocket, False);
    end;
  begin
    if (TSocketAPI.Connect(ASocket, Addr.ai_addr, Addr.ai_addrlen) = 0)
      or (GetLastError = EINPROGRESS) then
    begin
      // EVFILT_WRITE ֻ�����ж� Connect �ɹ����
      // �������� EV_ONESHOT ��־, ���䴥���������Զ��� kqueue ������ɾ��
      if not _KqueueCtl(EV_ADD or EV_ONESHOT, ASocket, EVFILT_WRITE, kqConnect, ACallback) then
      begin
        _Failed2;
        Exit(False);
      end;
    end else
    begin
      _Failed2;
      Exit(False);
    end;

    Result := True;
  end;
var
  LHints: TRawAddrInfo;
  P, LAddrInfo: PRawAddrInfo;
  LSocket: THandle;
begin
  FillChar(LHints, SizeOf(TRawAddrInfo), 0);
  LHints.ai_family := AF_UNSPEC;
  LHints.ai_socktype := SOCK_STREAM;
  LHints.ai_protocol := IPPROTO_TCP;
  LAddrInfo := TSocketAPI.GetAddrInfo(AHost, APort, LHints);
  if (LAddrInfo = nil) then
  begin
    _Failed1;
    Exit(-1);
  end;

  P := LAddrInfo;
  try
    while (LAddrInfo <> nil) do
    begin
      LSocket := TSocketAPI.NewSocket(LAddrInfo.ai_family, LAddrInfo.ai_socktype,
        LAddrInfo.ai_protocol);
      if (LSocket = INVALID_HANDLE_VALUE) then
      begin
        _Failed1;
        Exit(-1);
      end;

      TSocketAPI.SetNonBlock(LSocket, True);
      TSocketAPI.SetReUseAddr(LSocket, True);
      SetKeepAlive(LSocket);
      SetNoSigPipe(LSocket);

      if _Connect(LSocket, LAddrInfo) then Exit(0);

      LAddrInfo := PRawAddrInfo(LAddrInfo.ai_next);
    end;
  finally
    TSocketAPI.FreeAddrInfo(P);
  end;

  _Failed1;
  Result := -1;
end;

function TKqueueLoop.Listen(const AHost: string; APort: Word;
  const ACallback: TProc<THandle, Boolean>): Integer;
var
  LHints: TRawAddrInfo;
  P, LAddrInfo: PRawAddrInfo;
  LSocket: THandle;

  procedure _Failed;
  begin
    if (LSocket <> INVALID_HANDLE_VALUE) then
      TSocketAPI.CloseSocket(LSocket);

    if Assigned(ACallback) then
      ACallback(LSocket, False);
  end;

  procedure _Success;
  begin
    TriggerListened(LSocket);

    if Assigned(ACallback) then
      ACallback(LSocket, True);
  end;

begin
  LSocket := INVALID_HANDLE_VALUE;
  FillChar(LHints, SizeOf(TRawAddrInfo), 0);

  LHints.ai_flags := AI_PASSIVE;
  LHints.ai_family := AF_UNSPEC;
  LHints.ai_socktype := SOCK_STREAM;
  LHints.ai_protocol := IPPROTO_TCP;
  LAddrInfo := TSocketAPI.GetAddrInfo(AHost, APort, LHints);
  if (LAddrInfo = nil) then
  begin
    _Failed;
    Exit(-1);
  end;

  P := LAddrInfo;
  try
    while (LAddrInfo <> nil) do
    begin
      LSocket := TSocketAPI.NewSocket(LAddrInfo.ai_family, LAddrInfo.ai_socktype,
        LAddrInfo.ai_protocol);
      if (LSocket = INVALID_HANDLE_VALUE) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        _Failed;
        Exit(-1);
      end;

      TSocketAPI.SetNonBlock(LSocket, True);
      TSocketAPI.SetReUseAddr(LSocket, True);
      SetNoSigPipe(LSocket);

      if (TSocketAPI.Bind(LSocket, LAddrInfo.ai_addr, LAddrInfo.ai_addrlen) < 0) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        _Failed;
        Exit(-1);
      end;

      if (TSocketAPI.Listen(LSocket) < 0) then
      begin
        _Failed;
        Exit(-1);
      end;

      // �����ɹ�֮��, ��ʼ���Ӷ��¼�
      // ����Socket�Ķ��¼�������ʾ�������ӵ���
      if not _KqueueCtl(EV_ADD or EV_CLEAR or EV_DISPATCH, LSocket, EVFILT_READ, kqAccept, nil) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        _Failed;
        Exit(-1);
      end;

      _Success;

      // ����˿ڴ���0�������е�ַͳһ���׸����䵽�Ķ˿�
      if (APort = 0) and (LAddrInfo.ai_next <> nil) then
        Psockaddr_in(LAddrInfo.ai_next.ai_addr).sin_port := Psockaddr_in(LAddrInfo.ai_addr).sin_port;

      LAddrInfo := PRawAddrInfo(LAddrInfo.ai_next);
    end;
  finally
    TSocketAPI.FreeAddrInfo(P);
  end;

  Result := 0;
end;

function TKqueueLoop.Send(ASocket: THandle; const ABuf; ALen: Integer;
  const ACallback: TProc<THandle, Boolean>): Integer;
var
  LSocketSendQueue: TList<PSendItem>;
  LSendItem: PSendItem;

  procedure _Failed;
  begin
    System.TMonitor.Enter(LSocketSendQueue);
    try
      _ClearSendQueue(LSocketSendQueue);
    finally
      System.TMonitor.Exit(LSocketSendQueue);
    end;

    if Assigned(ACallback) then
      ACallback(ASocket, False);

    if (TSocketAPI.CloseSocket(ASocket) = 0) then
      TriggerDisconnected(ASocket);
  end;

begin
  // ��ȡSocket���Ͷ���
  System.TMonitor.Enter(FSendQueue);
  try
    if not FSendQueue.TryGetValue(ASocket, LSocketSendQueue) then
    begin
      LSocketSendQueue := TList<PSendItem>.Create;
      FSendQueue.AddOrSetValue(ASocket, LSocketSendQueue);
    end;
  finally
    System.TMonitor.Exit(FSendQueue);
  end;

  // ��Ҫ���͵����ݼ��ص�����Socket���Ͷ�����
  LSendItem := System.New(PSendItem);
  LSendItem.Data := @ABuf;
  LSendItem.Size := ALen;
  LSendItem.Callback := ACallback;
  System.TMonitor.Enter(LSocketSendQueue);
  try
    LSocketSendQueue.Add(LSendItem);
  finally
    System.TMonitor.Exit(LSocketSendQueue);
  end;

  // ���� EVFILT_WRITE, �����¼�����ʱ�����������ͻ����п��пռ���
  // �����¼�������ִ��ʵ�ʵķ��Ͷ���
  if not _KqueueCtl(EV_ADD or EV_ONESHOT, ASocket, EVFILT_WRITE, kqWrite) then
  begin
    _Failed;
    Exit(-1);
  end;

  Result := ALen;
end;

function TKqueueLoop.ProcessIoEvent: Boolean;
  procedure _HandleAccept(ASocket: THandle; APerIoData: PPerIoData);
  var
    LRet: Integer;
    LSocket: THandle;
  begin
    while True do
    begin
      LRet := TSocketAPI.Accept(ASocket, nil, nil);

      // Acceptʧ��
      // EAGAIN ��Ҫ����
      // EMFILE ���̵��ļ�����Ѿ�������
      if (LRet <= 0) then
      begin
//        LRet := GetLastError;
//        Writeln('accept failed:', LRet);
        Break;
      end;

      LSocket := LRet;
      TSocketAPI.SetNonBlock(LSocket, True);
      TSocketAPI.SetReUseAddr(LSocket, True);
      SetKeepAlive(LSocket);
      SetNoSigPipe(LSocket);

      // ���ӽ����������Socket�Ķ��¼�
      if not _KqueueCtl(EV_ADD or EV_CLEAR or EV_DISPATCH, LSocket, EVFILT_READ, kqRead) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        TSocketAPI.CloseSocket(LSocket);
        Continue;
      end;

      TriggerConnected(LSocket, CT_ACCEPT);
    end;

    // ���¼��� EVFILT_READ, �Լ�������������
    if not _KqueueCtl(EV_ENABLE or EV_CLEAR or EV_DISPATCH, ASocket, EVFILT_READ, kqAccept) then
    begin
      {$IFDEF DEBUG}
      __RaiseLastOSError;
      {$ENDIF}
      TSocketAPI.CloseSocket(ASocket)
    end;
  end;

  procedure _HandleRead(ASocket: THandle; ACount: Integer; APerIoData: PPerIoData);
  var
    LRcvd: Integer;
  begin
    // �Է������Ͽ�����
    if (ACount <= 0) then
    begin
      if (TSocketAPI.CloseSocket(ASocket) = 0) then
        TriggerDisconnected(ASocket);
      Exit;
    end;

    while (ACount > 0) do
    begin
      LRcvd := TSocketAPI.Recv(ASocket, FRecvBuf[0], RCV_BUF_SIZE);

      // �Է������Ͽ�����
      if (LRcvd = 0) then
      begin
        if (TSocketAPI.CloseSocket(ASocket) = 0) then
          TriggerDisconnected(ASocket);
        Break;
      end;

      if (LRcvd < 0) then
      begin
        // ��Ҫ����
        if _Again(GetLastError) then Break;

        if (TSocketAPI.CloseSocket(ASocket) = 0) then
          TriggerDisconnected(ASocket);

        Exit;
      end;

      TriggerReceived(ASocket, @FRecvBuf[0], LRcvd);

      if (LRcvd < RCV_BUF_SIZE) then Break;

      Dec(ACount, LRcvd);
    end;

    // ���¼��� EVFILT_READ, �Լ�������������
    if not _KqueueCtl(EV_ENABLE or EV_CLEAR or EV_DISPATCH, ASocket, EVFILT_READ, kqRead, nil) then
    begin
      if (TSocketAPI.CloseSocket(ASocket) = 0) then
        TriggerDisconnected(ASocket);
    end;
  end;

  procedure _HandleConnect(ASocket: THandle; APerIoData: PPerIoData);
    procedure _Success;
    begin
      TriggerConnected(ASocket, CT_CONNECT);

      if Assigned(APerIoData.Callback) then
        APerIoData.Callback(ASocket, True);
    end;

    procedure _Failed;
    begin
      {$IFDEF DEBUG}
      __RaiseLastOSError;
      {$ENDIF}
      TSocketAPI.CloseSocket(ASocket);

      TriggerConnectFailed(ASocket);

      if Assigned(APerIoData.Callback) then
        APerIoData.Callback(ASocket, False);
    end;
  begin
    // Connectʧ��
    if (TSocketAPI.GetError(ASocket) <> 0) then
    begin
      _Failed;
      Exit;
    end;

    _Success;

    // ���ӳɹ�, ���Ӷ��¼�
    if not _KqueueCtl(EV_ADD or EV_CLEAR or EV_DISPATCH, ASocket, EVFILT_READ, kqRead, nil) then
    begin
      _Failed;
      Exit;
    end;
  end;

  procedure _HandleWrite(ASocket: THandle; APerIoData: PPerIoData);
  var
    LSocketSendQueue: TList<PSendItem>;
    LSendItem: PSendItem;
    LSent: Integer;
    LCallback: TProc<THandle, Boolean>;

    function _WriteContinue: Boolean;
    begin
      Result := _KqueueCtl(EV_ADD or EV_ONESHOT, ASocket, EVFILT_WRITE, kqWrite);
      if not Result then
      begin
        // �ر�Socket
        if (TSocketAPI.CloseSocket(ASocket) = 0) then
          TriggerDisconnected(ASocket);
      end;
    end;

    procedure _Failed;
    begin
      // ���ûص�
      if Assigned(LCallback) then
        LCallback(ASocket, False);
    end;

    procedure _Success;
    begin
      // ���ͳɹ�, �Ƴ��ѷ��ͳɹ�������
      System.Dispose(LSendItem);
      if (LSocketSendQueue.Count > 0) then
        LSocketSendQueue.Delete(0);

      // ��������л�������, ��������
      if (LSocketSendQueue.Count > 0) then
        _WriteContinue;

      // ���ûص�
      if Assigned(LCallback) then
        LCallback(ASocket, True);
    end;

  begin
    LCallback := nil;

    // ��ȡSocket���Ͷ���
    if (FSendQueue = nil) then Exit;
    System.TMonitor.Enter(FSendQueue);
    try
      if not FSendQueue.TryGetValue(ASocket, LSocketSendQueue) then
        Exit;
    finally
      System.TMonitor.Exit(FSendQueue);
    end;

    // ��ȡSocket���Ͷ����еĵ�һ������
    if (LSocketSendQueue = nil) then Exit;
    System.TMonitor.Enter(LSocketSendQueue);
    try
      if (LSocketSendQueue.Count <= 0) then
        Exit;

      LSendItem := LSocketSendQueue.Items[0];
      LCallback := LSendItem.Callback;

      // ȫ���������
      if (LSendItem.Size <= 0) then
      begin
        _Success;
        Exit;
      end;

      // ��������
      LSent := TSocketAPI.Send(ASocket, LSendItem.Data^, LSendItem.Size);

      // ���ͳɹ�
      if (LSent > 0) then
      begin
        Inc(LSendItem.Data, LSent);
        Dec(LSendItem.Size, LSent);
      end else
      // ���ӶϿ����ʹ���
      if (LSent = 0) or not _Again(GetLastError) then
      begin
        if (TSocketAPI.CloseSocket(ASocket) = 0) then
          TriggerDisconnected(ASocket);
        _Failed;
        Exit;
      end;

      // �������� EVFILT_WRITE �¼�
      // EVFILT_WRITE �������������
      if not _WriteContinue then
        _Failed;
    finally
      System.TMonitor.Exit(LSocketSendQueue);
    end;
  end;
var
  LRet, I: Integer;
  LEvent: TKEvent;
  LPerIoData: PPerIoData;
  LSocket: THandle;
begin
  LRet := kevent(FKqueueHandle, nil, 0, @FEventList[0], MAX_EVENT_COUNT, nil);
  if (LRet < 0) then
  begin
    LRet := GetLastError;
//    Writeln('error:', LRet);
    // EINTR, kevent ���ñ�ϵͳ�жϴ��, ���Խ�������
    Exit(LRet = EINTR);
  end;

  for I := 0 to LRet - 1 do
  begin
    LEvent := FEventList[I];
    LPerIoData := LEvent.uData;

    if (LPerIoData = nil) then Continue;

    try
      LSocket := LPerIoData.Socket;

      // �쳣�¼�
      if (LEvent.Flags and EV_ERROR <> 0) then
      begin
        Writeln('event:', IntToHex(LEvent.Filter), ' socket:', LPerIoData.Socket, ' flags:', IntToHex(LEvent.Flags), ' action:', Integer(LPerIoData.Action));

        if Assigned(LPerIoData.Callback) then
          LPerIoData.Callback(LSocket, False);

        if (TSocketAPI.CloseSocket(LSocket) = 0) then
          TriggerDisconnected(LSocket);

        Continue;
      end;

      // ���ݿɶ�
      if (LEvent.Filter = EVFILT_READ) then
      begin
        case LPerIoData.Action of
          // ���µĿͻ�������
          kqAccept: _HandleAccept(LSocket, LPerIoData);
        else
          // �յ�������
          _HandleRead(LSocket, LEvent.Data, LPerIoData);
        end;
      end;

      // ���ݿ�д
      if (LEvent.Filter = EVFILT_WRITE) then
      begin
        case LPerIoData.Action of
          // ���ӳɹ�
          kqConnect: _HandleConnect(LSocket, LPerIoData);
        else
          // ���Է�������
          _HandleWrite(LSocket, LPerIoData);
        end;
      end;
    finally
      FreeIoData(LPerIoData);
    end;
  end;

  Result := True;
end;

end.
